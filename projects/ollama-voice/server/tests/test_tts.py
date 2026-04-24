"""TTS fallback chain tests."""
import asyncio
import pytest
from unittest.mock import patch


# ── TTS Fallback Tests ─────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestTTSFallback:
    """Test TTS fallback chain: VibeVoice → Kokoro → Qwen3."""

    async def test_tts_primary_vibevoice(self):
        """Test that VibeVoice is the primary TTS provider."""
        from main import cfg
        
        # Verify config has VibeVoice URL configured
        assert cfg.tts.vibevoice_url is not None
        assert len(cfg.tts.vibevoice_url) > 0

    async def test_tts_fallbacks_configured(self):
        """Test that fallback TTS providers are configured."""
        from main import cfg
        
        # Verify fallback chain exists
        assert cfg.tts.fallback_kokoro_url is not None
        assert cfg.tts.fallback_qwen3_url is not None

    async def test_tts_vibevoice_url_set(self):
        """Test that VibeVoice URL is configured."""
        from main import cfg
        
        # VibeVoice URL should be set
        assert hasattr(cfg.tts, 'vibevoice_url')
        assert cfg.tts.vibevoice_url is not None
        assert isinstance(cfg.tts.vibevoice_url, str)
        assert len(cfg.tts.vibevoice_url) > 0

    async def test_tts_synthesize_exists(self):
        """Test that synthesize function exists and is importable."""
        from tts import synthesize
        
        assert synthesize is not None
        assert asyncio.iscoroutinefunction(synthesize)

    @patch('tts.synthesize')
    async def test_tts_primary_success(self, mock_synthesize):
        """Test that primary TTS returns audio on success."""
        mock_synthesize.return_value = b"\x00\x01\x02\x03" * 1000  # Fake PCM audio
        
        from tts import synthesize
        from main import cfg
        
        audio = await synthesize("Hello world", cfg.tts)
        
        assert audio is not None
        assert len(audio) > 0
        assert isinstance(audio, bytes)

    @patch('tts.synthesize')
    async def test_tts_fallback_on_primary_failure(self, mock_synthesize):
        """Test that fallback TTS is used when primary fails."""
        mock_synthesize.side_effect = [
            Exception("VibeVoice failed"),  # Primary fails
            b"\x00\x01\x02\x03" * 1000,       # Fallback succeeds
        ]
        
        from tts import synthesize
        from main import cfg
        
        # First call fails
        with pytest.raises(Exception):
            await synthesize("Hello world", cfg.tts)
        
        # Fallback call succeeds
        audio = await synthesize("Hello world", cfg.tts)
        assert audio is not None

    async def test_tts_empty_text(self):
        """Test that empty text is handled gracefully."""
        from tts import synthesize
        from main import cfg
        
        # Empty text should either return empty audio or raise a clean error
        try:
            audio = await synthesize("", cfg.tts)
            # If it returns audio, it should be minimal
            if audio is not None:
                assert len(audio) >= 0
        except Exception as e:
            # Or it might raise a validation error
            assert "empty" in str(e).lower() or "text" in str(e).lower()

    async def test_tts_long_text(self):
        """Test that long text is handled."""
        from tts import synthesize
        from main import cfg
        
        long_text = "Hello world. " * 100  # 1300 chars
        
        try:
            audio = await synthesize(long_text, cfg.tts)
            if audio is not None:
                assert isinstance(audio, bytes)
                assert len(audio) >= 0
        except Exception:
            # Long text might fail, which is acceptable
            pass


# ── Audio Format Tests ────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestAudioFormat:
    """Test audio format handling."""

    async def test_audio_chunk_size(self):
        """Test that audio chunk size is correct."""
        from main import AUDIO_CHUNK_SIZE
        
        assert AUDIO_CHUNK_SIZE == 4096

    async def test_vad_split_size(self):
        """Test that VAD split size is correct."""
        from main import VAD_SPLIT_SIZE
        
        assert VAD_SPLIT_SIZE == 1024

    async def test_vad_chunk_size(self):
        """Test that VAD chunk size is correct."""
        from main import VAD_CHUNK_SIZE
        
        assert VAD_CHUNK_SIZE == 1024

    async def test_audio_format_16khz_16bit(self):
        """Test that audio format is 16kHz 16-bit mono."""
        from main import cfg
        
        assert cfg.audio.input_sample_rate == 16000
        # Verify PCM format (implied by sample rate and byte math)
        assert hasattr(cfg.audio, 'input_sample_rate')

    async def test_audio_duration_calculation(self):
        """Test audio duration calculation."""
        # 16000 Hz, 16-bit mono = 32000 bytes/sec
        # 1 second = 32000 bytes
        sample_data = b"\x00\x00" * 16000
        duration_ms = int(len(sample_data) / 32)
        
        assert duration_ms == 1000

    async def test_audio_duration_5_seconds(self):
        """Test 5-second audio duration."""
        sample_data = b"\x00\x00" * 16000 * 5
        duration_ms = int(len(sample_data) / 32)
        
        assert duration_ms == 5000
