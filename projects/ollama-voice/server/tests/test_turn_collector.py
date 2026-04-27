"""TurnCollector state-machine tests."""
import pytest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

from hands_free import TurnCollector, TurnEvent


CHUNK = b"\x00" * 1024  # one VAD-window chunk


def _build_cfg(
    *,
    silence_ms: int = 200,
    max_listen_secs: int = 15,
    min_audio_bytes: int = 8000,
    smart_turn_threshold: float = 0.5,
    speech_threshold: float = 0.5,
    window_size_samples: int = 512,
    input_sample_rate: int = 16000,
):
    """Minimal config namespace shaped like the real Config."""
    return SimpleNamespace(
        vad=SimpleNamespace(
            speech_threshold=speech_threshold,
            window_size_samples=window_size_samples,
        ),
        audio=SimpleNamespace(input_sample_rate=input_sample_rate),
        hands_free=SimpleNamespace(
            silence_ms=silence_ms,
            max_listen_secs=max_listen_secs,
            min_audio_bytes=min_audio_bytes,
            smart_turn_threshold=smart_turn_threshold,
        ),
    )


def _build_collector(smart_turn_value: float = 1.0, **cfg_kwargs):
    cfg = _build_cfg(**cfg_kwargs)
    vad = MagicMock()
    smart_turn = MagicMock()
    smart_turn.predict = AsyncMock(return_value=smart_turn_value)
    return TurnCollector(cfg, vad, smart_turn), vad, smart_turn


@pytest.mark.asyncio
class TestTurnCollectorIdle:
    async def test_silence_while_idle_yields_none(self):
        c, vad, _ = _build_collector()
        vad.get_speech_prob.return_value = 0.0
        event, audio = await c.feed(CHUNK)
        assert event == TurnEvent.NONE
        assert audio is None
        assert not c.is_collecting

    async def test_speech_triggers_onset(self):
        c, vad, _ = _build_collector()
        vad.get_speech_prob.return_value = 0.8
        event, audio = await c.feed(CHUNK)
        assert event == TurnEvent.ONSET
        assert audio is None
        assert c.is_collecting


@pytest.mark.asyncio
class TestTurnCollectorListening:
    async def test_continuing_speech_yields_none(self):
        c, vad, _ = _build_collector()
        vad.get_speech_prob.return_value = 0.8
        await c.feed(CHUNK)  # ONSET
        event, audio = await c.feed(CHUNK)
        assert event == TurnEvent.NONE
        assert audio is None
        assert c.is_collecting

    async def test_silence_under_threshold_keeps_listening(self):
        # silence_ms=200, chunk_ms=32 → silence_chunks_needed = 6.
        c, vad, _ = _build_collector(silence_ms=200)
        vad.get_speech_prob.return_value = 0.8
        await c.feed(CHUNK)  # ONSET
        vad.get_speech_prob.return_value = 0.0
        for _ in range(5):
            event, _ = await c.feed(CHUNK)
            assert event == TurnEvent.NONE
        assert c.is_collecting


@pytest.mark.asyncio
class TestTurnCollectorTurnEnd:
    async def test_too_short_resets(self):
        # silence_chunks_needed = 64/32 = 2; min_audio_bytes huge → too short
        c, vad, _ = _build_collector(silence_ms=64, min_audio_bytes=10_000_000)
        vad.get_speech_prob.return_value = 0.8
        await c.feed(CHUNK)  # ONSET
        vad.get_speech_prob.return_value = 0.0
        await c.feed(CHUNK)  # silence #1
        event, audio = await c.feed(CHUNK)  # silence #2 → threshold met
        assert event == TurnEvent.TOO_SHORT
        assert audio is None
        assert not c.is_collecting

    async def test_smart_turn_complete_returns_audio(self):
        # smart_turn returns 1.0 (above threshold) → turn complete
        c, vad, smart_turn = _build_collector(
            silence_ms=64, min_audio_bytes=0, smart_turn_value=1.0,
        )
        vad.get_speech_prob.return_value = 0.8
        await c.feed(CHUNK)  # ONSET
        await c.feed(CHUNK)
        await c.feed(CHUNK)
        vad.get_speech_prob.return_value = 0.0
        await c.feed(CHUNK)  # silence #1
        event, audio = await c.feed(CHUNK)  # silence #2 → threshold + smart-turn complete
        assert event == TurnEvent.COMPLETE
        assert audio is not None
        assert len(audio) >= 4 * len(CHUNK)
        assert not c.is_collecting
        smart_turn.predict.assert_awaited_once()

    async def test_smart_turn_incomplete_keeps_listening(self):
        # smart_turn returns 0.1 (below threshold) → keep listening
        c, vad, smart_turn = _build_collector(
            silence_ms=64, min_audio_bytes=0, smart_turn_value=0.1,
        )
        vad.get_speech_prob.return_value = 0.8
        await c.feed(CHUNK)  # ONSET
        vad.get_speech_prob.return_value = 0.0
        await c.feed(CHUNK)  # silence #1
        event, audio = await c.feed(CHUNK)  # silence #2 → threshold met but smart-turn says no
        assert event == TurnEvent.NONE
        assert audio is None
        assert c.is_collecting  # still listening
        smart_turn.predict.assert_awaited_once()

    async def test_max_listen_caps_turn_skipping_smart_turn(self, monkeypatch):
        """When elapsed >= max_listen_secs, the SmartTurn gate is skipped and the turn completes."""
        import hands_free
        # SmartTurn would say "not done" — ensures completion is from cap, not gate.
        c, vad, smart_turn = _build_collector(
            silence_ms=64, min_audio_bytes=0, max_listen_secs=1, smart_turn_value=0.0,
        )

        # Advance time after onset so elapsed > max_listen_secs.
        t = [100.0]
        monkeypatch.setattr(hands_free.time, "monotonic", lambda: t[0])

        vad.get_speech_prob.return_value = 0.8
        await c.feed(CHUNK)  # ONSET — listen_start = 100.0
        t[0] = 102.5  # 2.5s elapsed > 1s cap
        vad.get_speech_prob.return_value = 0.0
        # First silence chunk already exceeds max_listen_secs, so the
        # `silence_chunks < needed AND elapsed < cap` early-return short-circuits
        # and we fall through to the cap path.
        event, audio = await c.feed(CHUNK)
        assert event == TurnEvent.COMPLETE
        assert audio is not None
        smart_turn.predict.assert_not_called()


@pytest.mark.asyncio
class TestTurnCollectorReset:
    async def test_explicit_reset(self):
        c, vad, _ = _build_collector()
        vad.get_speech_prob.return_value = 0.8
        await c.feed(CHUNK)  # ONSET
        assert c.is_collecting
        c.reset()
        assert not c.is_collecting
        # After reset, next non-speech chunk is just NONE.
        vad.get_speech_prob.return_value = 0.0
        event, audio = await c.feed(CHUNK)
        assert event == TurnEvent.NONE
        assert audio is None
