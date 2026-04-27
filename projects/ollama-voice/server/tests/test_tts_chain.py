"""TTS provider-chain ordering and fallback tests."""
import pytest

from tts import synthesize


class _StubProvider:
    """Records calls; returns a configured result (bytes / None / raises)."""

    def __init__(self, name: str, result):
        self.name = name
        self._result = result
        self.call_count = 0
        self.last_text: str | None = None

    async def synthesize(self, text, cfg):
        self.call_count += 1
        self.last_text = text
        if isinstance(self._result, BaseException):
            raise self._result
        return self._result


@pytest.mark.asyncio
class TestTTSProviderChain:
    """synthesize() with injected providers — verify chain semantics."""

    async def test_first_provider_wins(self):
        from main import cfg
        p1 = _StubProvider("A", b"audio-A")
        p2 = _StubProvider("B", b"audio-B")
        result = await synthesize("hi", cfg.tts, providers=[p1, p2])
        assert result == b"audio-A"
        assert p1.call_count == 1
        assert p2.call_count == 0  # short-circuited

    async def test_falls_through_to_second_on_none(self):
        from main import cfg
        p1 = _StubProvider("A", None)
        p2 = _StubProvider("B", b"audio-B")
        result = await synthesize("hi", cfg.tts, providers=[p1, p2])
        assert result == b"audio-B"
        assert p1.call_count == 1
        assert p2.call_count == 1

    async def test_all_fail_returns_none(self):
        from main import cfg
        providers = [_StubProvider(f"P{i}", None) for i in range(3)]
        result = await synthesize("hi", cfg.tts, providers=providers)
        assert result is None
        assert all(p.call_count == 1 for p in providers)

    async def test_empty_text_short_circuits(self):
        """_clean_text strips markdown; ``***`` becomes empty and no provider runs."""
        from main import cfg
        p1 = _StubProvider("A", b"audio-A")
        result = await synthesize("***", cfg.tts, providers=[p1])
        assert result is None
        assert p1.call_count == 0

    async def test_long_text_truncated(self):
        from main import cfg
        from tts import MAX_TTS_CHARS
        long_text = "a" * (MAX_TTS_CHARS + 500)
        p1 = _StubProvider("A", b"audio-A")
        await synthesize(long_text, cfg.tts, providers=[p1])
        assert p1.last_text is not None
        # truncation happens before _clean_text but after; final text is at most MAX_TTS_CHARS
        assert len(p1.last_text) <= MAX_TTS_CHARS

    async def test_provider_exception_propagates(self):
        """A provider raising is not caught by the chain — it bubbles up.

        This is by design: providers are expected to swallow their own errors
        and return None. An exception means a programmer mistake or a
        provider that breaks the contract.
        """
        from main import cfg
        p1 = _StubProvider("A", RuntimeError("boom"))
        p2 = _StubProvider("B", b"audio-B")
        with pytest.raises(RuntimeError, match="boom"):
            await synthesize("hi", cfg.tts, providers=[p1, p2])
        assert p1.call_count == 1
        assert p2.call_count == 0
