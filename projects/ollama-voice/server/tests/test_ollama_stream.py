"""Ollama SSE parser tests using httpx.MockTransport."""
import json
import functools

import httpx
import pytest

import ollama
from config import OllamaConfig


def _sse(*chunks: dict) -> str:
    """Build an SSE response body from JSON chunks, terminated with [DONE]."""
    lines = [f"data: {json.dumps(c)}" for c in chunks]
    lines.append("data: [DONE]")
    return "\n".join(lines) + "\n"


def _delta(text: str) -> dict:
    return {"choices": [{"delta": {"content": text}}]}


def _install_transport(monkeypatch, handler):
    """Wrap httpx.AsyncClient inside the ollama module to use a MockTransport."""
    transport = httpx.MockTransport(handler)
    real_cls = httpx.AsyncClient

    def factory(**kwargs):
        kwargs.setdefault("transport", transport)
        return real_cls(**kwargs)

    monkeypatch.setattr(ollama.httpx, "AsyncClient", factory)


async def _collect(gen):
    out = []
    async for delta, accumulated in gen:
        out.append((delta, accumulated))
    return out


@pytest.mark.asyncio
class TestStreamHappyPath:
    async def test_yields_deltas_and_accumulates(self, monkeypatch):
        body = _sse(_delta("Hello"), _delta(", "), _delta("world!"))

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        result = await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))
        assert [d for d, _ in result] == ["Hello", ", ", "world!"]
        assert [a for _, a in result] == ["Hello", "Hello, ", "Hello, world!"]

    async def test_empty_deltas_skipped(self, monkeypatch):
        body = _sse(_delta(""), _delta("x"), _delta(""))

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        result = await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))
        assert [d for d, _ in result] == ["x"]

    async def test_done_marker_terminates_stream(self, monkeypatch):
        # Anything after [DONE] should be ignored.
        body = _sse(_delta("kept")) + 'data: {"choices":[{"delta":{"content":"ignored"}}]}\n'

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        result = await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))
        assert [d for d, _ in result] == ["kept"]


@pytest.mark.asyncio
class TestStreamErrors:
    async def test_http_error_raises_with_detail(self, monkeypatch):
        def handler(request):
            return httpx.Response(503, text="upstream offline")

        _install_transport(monkeypatch, handler)
        with pytest.raises(RuntimeError) as exc_info:
            await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))
        msg = str(exc_info.value)
        assert "503" in msg
        assert "upstream offline" in msg

    async def test_in_band_error_payload_raises(self, monkeypatch):
        body = (
            f'data: {json.dumps(_delta("partial "))}\n'
            f'data: {json.dumps({"error": {"message": "model crashed"}})}\n'
        )

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        with pytest.raises(RuntimeError, match="model crashed"):
            await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))

    async def test_string_error_payload_raises(self, monkeypatch):
        body = f'data: {json.dumps({"error": "bad request"})}\n'

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        with pytest.raises(RuntimeError, match="bad request"):
            await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))


@pytest.mark.asyncio
class TestStreamMalformed:
    async def test_malformed_json_chunk_skipped(self, monkeypatch):
        body = (
            'data: {bad json}\n'
            f'data: {json.dumps(_delta("recovered"))}\n'
            'data: [DONE]\n'
        )

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        result = await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))
        assert [d for d, _ in result] == ["recovered"]

    async def test_missing_choices_field_skipped(self, monkeypatch):
        body = (
            f'data: {json.dumps({"unexpected": "shape"})}\n'
            f'data: {json.dumps(_delta("recovered"))}\n'
            'data: [DONE]\n'
        )

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        result = await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))
        assert [d for d, _ in result] == ["recovered"]

    async def test_non_data_lines_ignored(self, monkeypatch):
        body = (
            'event: ping\n'
            ': comment line\n'
            f'data: {json.dumps(_delta("ok"))}\n'
            'data: [DONE]\n'
        )

        def handler(request):
            return httpx.Response(200, text=body)

        _install_transport(monkeypatch, handler)
        result = await _collect(ollama.stream_ollama_tokens("hi", OllamaConfig()))
        assert [d for d, _ in result] == ["ok"]


@pytest.mark.asyncio
class TestStreamRequestShape:
    async def test_request_includes_system_prompt_and_history(self, monkeypatch):
        captured = {}

        def handler(request):
            captured["body"] = json.loads(request.content)
            return httpx.Response(200, text=_sse(_delta("ok")))

        _install_transport(monkeypatch, handler)
        history = [{"role": "user", "content": "prior"}]
        await _collect(ollama.stream_ollama_tokens(
            "hi", OllamaConfig(),
            system_prompt="be helpful",
            history=history,
        ))
        msgs = captured["body"]["messages"]
        assert msgs[0] == {"role": "system", "content": "be helpful"}
        assert msgs[1] == history[0]
        assert msgs[-1] == {"role": "user", "content": "hi"}
        assert captured["body"]["stream"] is True
