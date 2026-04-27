"""End-to-end tests for hands_free_processor.

Spawns the processor as a task, pushes audio chunks onto the queue, and
observes the side effects (messages sent over the WS, transcribe/LLM calls,
session.history). Covers the major branches: speech onset, full turn,
empty transcript, too-short turn, echo-drain while busy, and busy→idle
resumption.
"""
import asyncio
import contextlib
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest

from config import Config
from hands_free import hands_free_processor
from session import ServerState, Session


CHUNK = b"\x00" * 1024  # one VAD-window chunk


# ── Test scaffolding ──────────────────────────────────────────────────────


def _make_session() -> Session:
    ws = AsyncMock()
    ws.send_json = AsyncMock()
    ws.send_bytes = AsyncMock()
    ws.close = AsyncMock()
    s = Session(ws=ws, conn_id="hf", mode="hands_free", system_prompt=None)
    s.hf_audio_q = asyncio.Queue(maxsize=200)
    return s


def _hf_test_cfg() -> Config:
    """Cfg tuned for fast hands-free tests: 64ms silence, no min-audio gate."""
    c = Config()
    c.hands_free.silence_ms = 64       # silence_chunks_needed = 2
    c.hands_free.max_listen_secs = 60  # avoid the cap during tests
    c.hands_free.min_audio_bytes = 0
    c.hands_free.smart_turn_threshold = 0.5
    return c


def _setup(monkeypatch, *, transcript: str = "hello", llm_response: str = "world"):
    """Build a fresh test fixture with all I/O dependencies stubbed."""
    transcribe = AsyncMock(return_value=transcript)
    generate_response = AsyncMock(return_value=llm_response)
    monkeypatch.setattr("hands_free.transcribe", transcribe)
    monkeypatch.setattr("hands_free.generate_response", generate_response)

    vad = MagicMock()
    vad.get_speech_prob = MagicMock(return_value=0.0)

    smart_turn = MagicMock()
    smart_turn.predict = AsyncMock(return_value=1.0)  # always "turn complete"

    return SimpleNamespace(
        session=_make_session(),
        cfg=_hf_test_cfg(),
        vad=vad,
        smart_turn=smart_turn,
        transcribe=transcribe,
        generate_response=generate_response,
    )


def _vad_returns(*probs: float):
    """Build a side_effect callable that yields the given probabilities then 0.0 forever."""
    it = iter(probs)

    def side_effect(_chunk):
        try:
            return next(it)
        except StopIteration:
            return 0.0

    return side_effect


def _sent_types(session: Session) -> list[str]:
    return [c.args[0]["type"] for c in session.ws.send_json.call_args_list]


async def _wait_for_message(session: Session, msg_type: str, *, timeout: float = 1.0):
    """Poll until a message of the given type appears, or fail with a clear diff."""
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        if msg_type in _sent_types(session):
            return
        await asyncio.sleep(0.005)
    raise AssertionError(
        f"Did not observe {msg_type!r} within {timeout}s; saw: {_sent_types(session)}"
    )


async def _wait_for_quiet(session: Session, *, timeout: float = 1.0):
    """Wait for the queue to drain, plus a brief tick for the processor to settle."""
    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        if session.hf_audio_q.empty():
            await asyncio.sleep(0.05)
            return
        await asyncio.sleep(0.005)


@contextlib.asynccontextmanager
async def _run_processor(hf):
    """Spawn the processor task; cancel cleanly on exit."""
    task = asyncio.create_task(hands_free_processor(
        hf.session, hf.cfg, hf.vad, hf.smart_turn, "be helpful",
    ))
    try:
        yield task
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


# ── Tests ─────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
class TestSpeechOnset:
    async def test_first_speech_chunk_sends_listening_start(self, monkeypatch):
        hf = _setup(monkeypatch)
        hf.vad.get_speech_prob.return_value = 0.8

        async with _run_processor(hf):
            await hf.session.hf_audio_q.put(CHUNK)
            await _wait_for_message(hf.session, "listening_start")

        assert "listening_start" in _sent_types(hf.session)
        # No transcript yet — speech is still ongoing.
        hf.transcribe.assert_not_awaited()


@pytest.mark.asyncio
class TestFullTurn:
    async def test_speech_then_silence_runs_full_pipeline(self, monkeypatch):
        hf = _setup(monkeypatch)
        # 3 speech chunks + 2 silence chunks (>= silence_chunks_needed=2).
        hf.vad.get_speech_prob.side_effect = _vad_returns(0.8, 0.8, 0.8, 0.0, 0.0)

        async with _run_processor(hf):
            for _ in range(5):
                await hf.session.hf_audio_q.put(CHUNK)
            await _wait_for_message(hf.session, "transcript")
            await _wait_for_quiet(hf.session)

        types = _sent_types(hf.session)
        assert "listening_start" in types
        assert "listening_end" in types
        assert "transcript" in types
        # Order: listening_start → listening_end → transcript
        assert types.index("listening_start") < types.index("listening_end")
        assert types.index("listening_end") <= types.index("transcript")

        # Pipeline calls
        hf.transcribe.assert_awaited_once()
        # First positional arg to transcribe is the audio bytes.
        sent_audio = hf.transcribe.await_args.args[0]
        assert isinstance(sent_audio, bytes)
        assert len(sent_audio) >= 3 * len(CHUNK)  # at least the 3 speech chunks

        hf.generate_response.assert_awaited_once()
        # generate_response gets the transcript as 3rd positional arg.
        assert hf.generate_response.await_args.args[2] == "hello"

        # History appended
        assert hf.session.history == [
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "world"},
        ]


@pytest.mark.asyncio
class TestEmptyTranscript:
    async def test_empty_transcript_aborts_without_llm(self, monkeypatch):
        hf = _setup(monkeypatch, transcript="")
        hf.vad.get_speech_prob.side_effect = _vad_returns(0.8, 0.8, 0.0, 0.0)

        async with _run_processor(hf):
            for _ in range(4):
                await hf.session.hf_audio_q.put(CHUNK)
            # Two listening_end messages will fire across the lifetime
            # (one for the empty-transcript abort). Wait for the abort.
            await _wait_for_message(hf.session, "listening_end")
            await _wait_for_quiet(hf.session)

        hf.transcribe.assert_awaited_once()       # STT did run
        hf.generate_response.assert_not_awaited()  # LLM did not
        assert "transcript" not in _sent_types(hf.session)
        assert hf.session.history == []


@pytest.mark.asyncio
class TestTooShortTurn:
    async def test_too_short_skips_stt(self, monkeypatch):
        hf = _setup(monkeypatch)
        hf.cfg.hands_free.min_audio_bytes = 100_000  # huge → never satisfied
        hf.vad.get_speech_prob.side_effect = _vad_returns(0.8, 0.0, 0.0)

        async with _run_processor(hf):
            for _ in range(3):
                await hf.session.hf_audio_q.put(CHUNK)
            await _wait_for_message(hf.session, "listening_end")
            await _wait_for_quiet(hf.session)

        # Neither STT nor LLM was invoked.
        hf.transcribe.assert_not_awaited()
        hf.generate_response.assert_not_awaited()
        # Listening was started and aborted.
        types = _sent_types(hf.session)
        assert "listening_start" in types
        assert "listening_end" in types


@pytest.mark.asyncio
class TestEchoDrainWhileBusy:
    async def test_chunks_dropped_while_responding(self, monkeypatch):
        hf = _setup(monkeypatch)
        hf.session.state = ServerState.RESPONDING  # simulate ongoing TTS
        hf.vad.get_speech_prob.return_value = 0.8

        async with _run_processor(hf):
            for _ in range(5):
                await hf.session.hf_audio_q.put(CHUNK)
            await _wait_for_quiet(hf.session)
            # Give the processor an extra tick to confirm it didn't process.
            await asyncio.sleep(0.05)

        assert hf.session.hf_audio_q.empty()
        # No collector activity — VAD never consulted because the busy
        # branch drains and continues before reaching collector.feed().
        hf.vad.get_speech_prob.assert_not_called()
        assert "listening_start" not in _sent_types(hf.session)


@pytest.mark.asyncio
class TestResumeAfterBusy:
    async def test_processor_resumes_when_state_returns_to_idle(self, monkeypatch):
        hf = _setup(monkeypatch)
        hf.session.state = ServerState.RESPONDING
        hf.vad.get_speech_prob.return_value = 0.8

        async with _run_processor(hf):
            # Push some chunks while busy — they should be drained silently.
            for _ in range(3):
                await hf.session.hf_audio_q.put(CHUNK)
            await _wait_for_quiet(hf.session)
            assert "listening_start" not in _sent_types(hf.session)

            # Transition back to IDLE; the next chunk should trigger onset.
            hf.session.state = ServerState.IDLE
            await hf.session.hf_audio_q.put(CHUNK)
            await _wait_for_message(hf.session, "listening_start")
