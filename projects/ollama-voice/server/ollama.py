"""Ollama client for LLM responses via OpenAI-compatible SSE endpoint."""

import asyncio
import json
import logging
from typing import AsyncGenerator
from urllib.parse import urlparse
import httpx
from config import OllamaConfig

log = logging.getLogger("ollama")

# Per-chunk read timeout: if no token received in 30s, abort the stream
PER_CHUNK_TIMEOUT = 30.0


async def stream_ollama_tokens(
    text: str,
    cfg: OllamaConfig,
    system_prompt: str | None = None,
    history: list[dict] | None = None,
) -> AsyncGenerator[tuple[str, str], None]:
    """Stream raw LLM token deltas, yielding (delta, accumulated_text) for each chunk.

    Raises RuntimeError with a descriptive message on any upstream failure
    (HTTP error, SSE timeout, in-band error payload). The caller is expected
    to surface the message to the user.
    """
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": text})

    async with httpx.AsyncClient(timeout=cfg.timeout) as client:
        async with client.stream(
            "POST",
            cfg.url,
            headers={"Content-Type": "application/json"},
            json={"model": cfg.model, "messages": messages, "stream": True},
        ) as resp:
            if resp.status_code >= 400:
                detail = ""
                try:
                    body = await resp.aread()
                    detail = body.decode("utf-8", errors="replace")[:200].strip()
                except Exception:
                    pass
                msg = f"Ollama HTTP {resp.status_code}"
                if detail:
                    msg = f"{msg}: {detail}"
                raise RuntimeError(msg)

            accumulated = ""
            line_iter = resp.aiter_lines()
            while True:
                try:
                    line = await asyncio.wait_for(
                        line_iter.__anext__(), timeout=PER_CHUNK_TIMEOUT
                    )
                except asyncio.TimeoutError:
                    raise RuntimeError(
                        f"Ollama SSE timeout: no token received in {PER_CHUNK_TIMEOUT:.0f}s"
                    )
                except StopAsyncIteration:
                    break
                if not line.startswith("data: "):
                    continue
                payload = line[6:].strip()
                if payload == "[DONE]":
                    break
                if len(payload) > 1048576:
                    log.warning("Oversized SSE payload (%d bytes), skipping", len(payload))
                    continue
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError as e:
                    log.warning("Failed to parse SSE chunk: %r — payload=%r", e, payload[:120])
                    continue
                if "error" in chunk:
                    err_msg = chunk["error"]
                    if isinstance(err_msg, dict):
                        err_msg = err_msg.get("message", str(err_msg))
                    raise RuntimeError(f"Ollama: {err_msg}")
                try:
                    delta = chunk["choices"][0]["delta"].get("content", "")
                except (KeyError, IndexError, TypeError):
                    continue
                if delta:
                    accumulated += delta
                    yield delta, accumulated


async def _probe_ollama_native(client: httpx.AsyncClient, base_url: str, model: str) -> dict | None:
    """Probe Ollama's native /api/tags endpoint."""
    try:
        resp = await client.get(f"{base_url}/api/tags")
        if resp.status_code != 200:
            return None
        models = [m["name"] for m in resp.json().get("models", [])]
        return {
            "status": "ok" if any(model in m for m in models) else "model_missing",
            "model": model,
            "available_models": models,
        }
    except Exception:
        return None


async def _probe_openai_compat(client: httpx.AsyncClient, base_url: str, model: str) -> dict | None:
    """Probe OpenAI-compatible /v1/models endpoint."""
    try:
        resp = await client.get(f"{base_url}/v1/models")
        if resp.status_code != 200:
            return None
        models = [m.get("id", "") for m in resp.json().get("data", [])]
        return {
            "status": "ok" if any(model in m for m in models) else "model_missing",
            "model": model,
            "available_models": models,
            "endpoint": "openai_compatible",
        }
    except Exception:
        return None


async def _probe_reachable(client: httpx.AsyncClient, base_url: str, model: str) -> dict | None:
    """Last resort: confirm the base URL responds at all."""
    try:
        await client.get(base_url)
        return {"status": "reachable", "model": model, "note": "model list unavailable"}
    except Exception:
        return None


_PROBES = (_probe_ollama_native, _probe_openai_compat, _probe_reachable)


async def check_ollama(cfg: OllamaConfig) -> dict:
    """Check if Ollama is reachable and the model is available.

    Tries probes in order and returns the first non-None result.

    Note: assumes cfg.url points to a dedicated Ollama endpoint. Path-based
    proxies that embed the model path (e.g. /ollama/v1/chat/completions) will
    break /api/tags and /v1/models probes. Set cfg.url to the proxy root or
    run Ollama on a dedicated sub-domain if you need these checks.
    """
    try:
        parsed = urlparse(cfg.url)
        base_url = f"{parsed.scheme}://{parsed.netloc}"
        async with httpx.AsyncClient(timeout=5.0) as client:
            for probe in _PROBES:
                result = await probe(client, base_url, cfg.model)
                if result is not None:
                    return result
        return {"status": "unreachable", "error": "Cannot reach Ollama server"}
    except Exception as e:
        return {"status": "unreachable", "error": str(e)}
