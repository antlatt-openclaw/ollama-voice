"""check_ollama probe-chain tests."""
import json

import httpx
import pytest

import ollama
from config import OllamaConfig


def _install_routes(monkeypatch, routes: dict[str, httpx.Response]):
    """Build a MockTransport that returns the response keyed by request URL path.

    Any path missing from `routes` raises ConnectError to simulate "no such endpoint".
    """
    def handler(request: httpx.Request) -> httpx.Response:
        # Match by path so the same handler covers both /api/tags and /v1/models.
        url = str(request.url)
        if url in routes:
            return routes[url]
        # Fallback: try matching by path
        path = request.url.path
        for k, v in routes.items():
            if k.endswith(path):
                return v
        raise httpx.ConnectError("not configured", request=request)

    transport = httpx.MockTransport(handler)
    real_cls = httpx.AsyncClient

    def factory(**kwargs):
        kwargs.setdefault("transport", transport)
        return real_cls(**kwargs)

    monkeypatch.setattr(ollama.httpx, "AsyncClient", factory)


def _native_response(models: list[str]) -> httpx.Response:
    return httpx.Response(200, json={"models": [{"name": m} for m in models]})


def _openai_response(models: list[str]) -> httpx.Response:
    return httpx.Response(200, json={"data": [{"id": m} for m in models]})


@pytest.mark.asyncio
class TestCheckOllamaNativeProbe:
    async def test_model_present(self, monkeypatch):
        cfg = OllamaConfig(model="llama3:8b")
        _install_routes(monkeypatch, {
            "/api/tags": _native_response(["llama3:8b", "qwen3:14b"]),
        })
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "ok"
        assert result["model"] == "llama3:8b"
        assert "llama3:8b" in result["available_models"]

    async def test_model_missing(self, monkeypatch):
        cfg = OllamaConfig(model="absent-model")
        _install_routes(monkeypatch, {
            "/api/tags": _native_response(["llama3:8b"]),
        })
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "model_missing"

    async def test_substring_match(self, monkeypatch):
        # `cfg.model` is matched as substring inside the listed names.
        cfg = OllamaConfig(model="llama3")
        _install_routes(monkeypatch, {
            "/api/tags": _native_response(["llama3:8b-instruct"]),
        })
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "ok"


@pytest.mark.asyncio
class TestCheckOllamaOpenAIFallback:
    async def test_falls_through_to_openai_compat_on_native_404(self, monkeypatch):
        cfg = OllamaConfig(model="qwen3:14b")
        _install_routes(monkeypatch, {
            "/api/tags": httpx.Response(404),
            "/v1/models": _openai_response(["qwen3:14b"]),
        })
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "ok"
        assert result["endpoint"] == "openai_compatible"

    async def test_openai_model_missing(self, monkeypatch):
        cfg = OllamaConfig(model="absent")
        _install_routes(monkeypatch, {
            "/api/tags": httpx.Response(404),
            "/v1/models": _openai_response(["other"]),
        })
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "model_missing"
        assert result["endpoint"] == "openai_compatible"


@pytest.mark.asyncio
class TestCheckOllamaReachableFallback:
    async def test_reachable_when_only_root_responds(self, monkeypatch):
        cfg = OllamaConfig()
        _install_routes(monkeypatch, {
            "/api/tags": httpx.Response(404),
            "/v1/models": httpx.Response(404),
            "/": httpx.Response(200, text="hello"),
        })
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "reachable"
        assert "model_list" in result["note"] or "model list" in result["note"]


@pytest.mark.asyncio
class TestCheckOllamaUnreachable:
    async def test_all_probes_fail(self, monkeypatch):
        cfg = OllamaConfig()
        _install_routes(monkeypatch, {})  # nothing configured → all ConnectError
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "unreachable"

    async def test_native_probe_returns_malformed_json(self, monkeypatch):
        # Garbage body should make probe 1 fail and fall through to probe 2.
        cfg = OllamaConfig(model="m")
        _install_routes(monkeypatch, {
            "/api/tags": httpx.Response(200, text="not json"),
            "/v1/models": _openai_response(["m"]),
        })
        result = await ollama.check_ollama(cfg)
        assert result["status"] == "ok"
        assert result["endpoint"] == "openai_compatible"
