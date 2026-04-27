"""Pipeline integration tests.

Wires `process_speech` / `handle_tts_only` end-to-end with stubbed STT, LLM,
and TTS. Verifies the message sequence on the wire, state lifecycle, history
behavior, and interrupt handling.
"""
import pytest
from unittest.mock import AsyncMock

from pipeline import _do_stt, handle_tts_only, process_speech
from session import ServerState, Session
from main import cfg


# ── Test helpers ──────────────────────────────────────────────────────────


def _make_session():
    """Real Session with an AsyncMock-backed websocket."""
    ws = AsyncMock()
    ws.send_json = AsyncMock()
    ws.send_bytes = AsyncMock()
    ws.close = AsyncMock()
    return Session(ws=ws, conn_id="t", mode="ptt", system_prompt=None)


def _sent_types(session) -> list[str]:
    """Ordered list of `type` field from JSON sent over the WS."""
    return [c.args[0]["type"] for c in session.ws.send_json.call_args_list]


@pytest.fixture
def stub_pipeline(monkeypatch):
    """Default mocks for STT / LLM / TTS — happy path responses."""
    transcribe = AsyncMock(return_value="hello")
    synthesize = AsyncMock(return_value=b"\x00\x00" * 500)  # 1000 bytes of silence

    async def default_stream(*a, **kw):
        yield "hi ", "hi "
        yield "there", "hi there"

    monkeypatch.setattr("pipeline.transcribe", transcribe)
    monkeypatch.setattr("pipeline.synthesize", synthesize)
    monkeypatch.setattr("pipeline.stream_ollama_tokens", default_stream)

    return type("StubPipeline", (), {
        "transcribe": transcribe,
        "synthesize": synthesize,
    })()


# ── _do_stt unit-ish tests ────────────────────────────────────────────────


@pytest.mark.asyncio
class TestDoStt:
    async def test_returns_transcript_and_sends_message(self, stub_pipeline):
        s = _make_session()
        result = await _do_stt(s, cfg, b"audio")
        assert result == "hello"
        assert _sent_types(s) == ["transcript"]
        assert s.state == ServerState.IDLE  # context manager unwound

    async def test_transcribe_exception_returns_none(self, monkeypatch):
        monkeypatch.setattr("pipeline.transcribe", AsyncMock(side_effect=RuntimeError("boom")))
        s = _make_session()
        result = await _do_stt(s, cfg, b"audio")
        assert result is None
        assert _sent_types(s) == ["error"]
        assert s.state == ServerState.IDLE

    async def test_empty_transcript_returns_none(self, monkeypatch):
        monkeypatch.setattr("pipeline.transcribe", AsyncMock(return_value=""))
        s = _make_session()
        result = await _do_stt(s, cfg, b"audio")
        assert result is None
        assert _sent_types(s) == ["error"]

    async def test_interrupted_during_stt_returns_none(self, monkeypatch):
        async def transcribe_then_interrupt(*a, **kw):
            return "hello"
        monkeypatch.setattr("pipeline.transcribe", transcribe_then_interrupt)
        s = _make_session()
        # Pre-set INTERRUPTED so the post-STT check fires.
        # We mark it after entering the context — easiest path: use a side-effecting transcribe.
        async def transcribe_and_set(*a, **kw):
            s.state = ServerState.INTERRUPTED
            return "hello"
        monkeypatch.setattr("pipeline.transcribe", transcribe_and_set)
        result = await _do_stt(s, cfg, b"audio")
        assert result is None  # interrupted check fires
        # send_if_active drops on INTERRUPTED so transcript never gets sent
        assert "transcript" not in _sent_types(s)


# ── process_speech happy path ─────────────────────────────────────────────


@pytest.mark.asyncio
class TestProcessSpeechHappyPath:
    async def test_full_turn_emits_expected_message_sequence(self, stub_pipeline):
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        types = _sent_types(s)
        # Required messages in order
        assert types.index("transcript") < types.index("response_start")
        assert types.index("response_start") < types.index("response_end")
        assert "response_delta" in types
        assert types.index("audio_start") < types.index("audio_end")
        assert types.index("audio_end") < types.index("response_end")

    async def test_history_appended_on_success(self, stub_pipeline):
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        assert len(s.history) == 2
        assert s.history[0] == {"role": "user", "content": "hello"}
        assert s.history[1]["role"] == "assistant"
        assert "hi there" in s.history[1]["content"]

    async def test_state_idle_after_success(self, stub_pipeline):
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        assert s.state == ServerState.IDLE

    async def test_audio_sent_as_binary(self, stub_pipeline):
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        assert s.ws.send_bytes.await_count >= 1


# ── process_speech failure modes ──────────────────────────────────────────


@pytest.mark.asyncio
class TestProcessSpeechFailures:
    async def test_stt_exception_aborts_with_error(self, monkeypatch):
        monkeypatch.setattr("pipeline.transcribe", AsyncMock(side_effect=RuntimeError("boom")))
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        assert "error" in _sent_types(s)
        assert "response_start" not in _sent_types(s)
        assert s.state == ServerState.IDLE
        assert s.history == []

    async def test_empty_stt_aborts_with_error(self, monkeypatch):
        monkeypatch.setattr("pipeline.transcribe", AsyncMock(return_value=""))
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        assert "error" in _sent_types(s)
        assert "response_start" not in _sent_types(s)
        assert s.history == []

    async def test_llm_failure_sends_error_no_history(self, stub_pipeline, monkeypatch):
        async def failing_stream(*a, **kw):
            raise RuntimeError("ollama down")
            yield  # pragma: no cover  unreachable
        monkeypatch.setattr("pipeline.stream_ollama_tokens", failing_stream)
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        types = _sent_types(s)
        assert "transcript" in types  # STT succeeded
        assert "response_start" in types
        assert "error" in types  # LLM failed
        # The error message should carry the upstream detail
        error_msg = next(
            c.args[0] for c in s.ws.send_json.call_args_list
            if c.args[0]["type"] == "error"
        )
        assert "ollama down" in error_msg["message"]
        assert s.state == ServerState.IDLE
        assert s.history == []

    async def test_tts_failure_still_completes_text_response(self, stub_pipeline, monkeypatch):
        # synthesize returns None — text response should still complete
        monkeypatch.setattr("pipeline.synthesize", AsyncMock(return_value=None))
        s = _make_session()
        await process_speech(s, cfg, b"audio", "be helpful")
        types = _sent_types(s)
        assert "response_end" in types
        assert "audio_start" not in types
        assert s.state == ServerState.IDLE
        # History still appended — text response is the canonical reply
        assert len(s.history) == 2


# ── Interrupt handling ────────────────────────────────────────────────────


@pytest.mark.asyncio
class TestProcessSpeechInterruption:
    async def test_interrupt_during_llm_stops_before_audio(self, stub_pipeline, monkeypatch):
        s = _make_session()

        async def interrupting_stream(*a, **kw):
            yield "a", "a"
            s.state = ServerState.INTERRUPTED
            yield "b", "ab"  # generate_response sees interrupt and breaks

        monkeypatch.setattr("pipeline.stream_ollama_tokens", interrupting_stream)
        await process_speech(s, cfg, b"audio", "be helpful")
        types = _sent_types(s)
        assert "audio_start" not in types
        assert "response_end" not in types
        assert s.state == ServerState.IDLE
        assert s.history == []

    async def test_interrupt_during_tts_drops_audio(self, stub_pipeline, monkeypatch):
        s = _make_session()

        async def synthesize_with_interrupt(text, cfg):
            s.state = ServerState.INTERRUPTED
            return b"\x00" * 1000

        monkeypatch.setattr("pipeline.synthesize", synthesize_with_interrupt)
        await process_speech(s, cfg, b"audio", "be helpful")
        types = _sent_types(s)
        assert "audio_start" not in types
        assert "audio_end" not in types
        assert "response_end" not in types
        assert s.state == ServerState.IDLE
        # No history appended because generate_response returned None on the interrupt path
        assert s.history == []


# ── handle_tts_only ───────────────────────────────────────────────────────


@pytest.mark.asyncio
class TestHandleTtsOnly:
    async def test_happy_path_emits_full_sequence(self, stub_pipeline):
        s = _make_session()
        await handle_tts_only(s, cfg, "say this")
        types = _sent_types(s)
        assert types.index("tts_only_start") < types.index("audio_start")
        assert types.index("audio_start") < types.index("audio_end")
        assert types.index("audio_end") < types.index("tts_only_end")
        assert s.state == ServerState.IDLE

    async def test_busy_session_ignored(self, stub_pipeline):
        s = _make_session()
        s.state = ServerState.RESPONDING
        await handle_tts_only(s, cfg, "say this")
        assert _sent_types(s) == []

    async def test_synthesis_failure_still_emits_end(self, stub_pipeline, monkeypatch):
        monkeypatch.setattr("pipeline.synthesize", AsyncMock(return_value=None))
        s = _make_session()
        await handle_tts_only(s, cfg, "say this")
        types = _sent_types(s)
        assert "tts_only_start" in types
        assert "audio_start" not in types
        assert "tts_only_end" in types  # finally block
        assert s.state == ServerState.IDLE


# ── Exception safety from in_state ────────────────────────────────────────


@pytest.mark.asyncio
class TestStateExceptionSafety:
    """The in_state context manager must guarantee IDLE on cancellation/exception."""

    async def test_cancelled_during_llm_still_returns_idle(self, stub_pipeline, monkeypatch):
        import asyncio
        s = _make_session()

        async def cancelling_stream(*a, **kw):
            yield "a", "a"
            raise asyncio.CancelledError()

        monkeypatch.setattr("pipeline.stream_ollama_tokens", cancelling_stream)
        with pytest.raises(asyncio.CancelledError):
            await process_speech(s, cfg, b"audio", "be helpful")
        # `in_state` finally ran, leaving IDLE
        assert s.state == ServerState.IDLE
