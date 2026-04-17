"""Ollama client for LLM responses via OpenAI-compatible SSE endpoint."""

import json
import logging
from typing import AsyncGenerator
from urllib.parse import urlparse
import httpx
from config import OllamaConfig

log = logging.getLogger("ollama")


async def stream_ollama_tokens(
    text: str,
    cfg: OllamaConfig,
    system_prompt: str | None = None,
    history: list[dict] | None = None,
) -> AsyncGenerator[tuple[str, str], None]:
    """Stream raw LLM token deltas, yielding (delta, accumulated_text) for each chunk."""
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": text})

    try:
        async with httpx.AsyncClient(timeout=cfg.timeout) as client:
            async with client.stream(
                "POST",
                cfg.url,
                headers={"Content-Type": "application/json"},
                json={
                    "model": cfg.model,
                    "messages": messages,
                    "stream": True,
                },
            ) as resp:
                resp.raise_for_status()
                accumulated = ""
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    payload = line[6:].strip()
                    if payload == "[DONE]":
                        break
                    try:
                        chunk = json.loads(payload)
                        delta = chunk["choices"][0]["delta"].get("content", "")
                    except Exception as e:
                        log.warning("Failed to parse SSE chunk: %r — payload=%r", e, payload[:120])
                        continue
                    if delta:
                        accumulated += delta
                        yield delta, accumulated

    except httpx.HTTPStatusError as e:
        log.error("HTTP %d error from %s: %s", e.response.status_code, cfg.url, e)
    except Exception as e:
        log.error("Streaming error: %s", e)


async def check_ollama(cfg: OllamaConfig) -> dict:
    """Check if Ollama is reachable and the model is available."""
    try:
        parsed = urlparse(cfg.url)
        base_url = f"{parsed.scheme}://{parsed.netloc}"
        async with httpx.AsyncClient(timeout=5.0) as client:
            # Try native Ollama /api/tags endpoint first
            try:
                resp = await client.get(f"{base_url}/api/tags")
                if resp.status_code == 200:
                    models = [m["name"] for m in resp.json().get("models", [])]
                    model_present = any(cfg.model in m for m in models)
                    return {
                        "status": "ok" if model_present else "model_missing",
                        "model": cfg.model,
                        "available_models": models,
                    }
            except Exception:
                pass  # /api/tags not available (e.g. OpenAI-compatible proxy)

            # Fallback: try a lightweight request to the configured endpoint
            try:
                resp = await client.get(f"{base_url}/v1/models")
                if resp.status_code == 200:
                    data = resp.json()
                    models = [m.get("id", "") for m in data.get("data", [])]
                    model_present = any(cfg.model in m for m in models)
                    return {
                        "status": "ok" if model_present else "model_missing",
                        "model": cfg.model,
                        "available_models": models,
                        "endpoint": "openai_compatible",
                    }
            except Exception:
                pass

            # Last resort: just check if the base URL is reachable
            try:
                resp = await client.get(base_url)
                return {"status": "reachable", "model": cfg.model, "note": "model list unavailable"}
            except Exception:
                return {"status": "unreachable", "error": "Cannot reach Ollama server"}

    except Exception as e:
        return {"status": "unreachable", "error": str(e)}
