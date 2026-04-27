"""Tests for env-var helpers and load_config."""
import pytest

from config import _env_float, _env_int, _env_str, load_config


# ── Helper-level tests ────────────────────────────────────────────────────


class TestEnvStr:
    def test_default_when_unset(self, monkeypatch):
        monkeypatch.delenv("FOO", raising=False)
        assert _env_str("FOO", default="bar") == "bar"

    def test_returns_value_when_set(self, monkeypatch):
        monkeypatch.setenv("FOO", "hello")
        assert _env_str("FOO", default="bar") == "hello"

    def test_required_raises_when_unset(self, monkeypatch):
        monkeypatch.delenv("FOO", raising=False)
        with pytest.raises(ValueError, match="FOO"):
            _env_str("FOO", required=True)

    def test_required_raises_when_blank(self, monkeypatch):
        monkeypatch.setenv("FOO", "")
        with pytest.raises(ValueError, match="FOO"):
            _env_str("FOO", required=True)


class TestEnvInt:
    def test_default(self, monkeypatch):
        monkeypatch.delenv("FOO", raising=False)
        assert _env_int("FOO", default=42) == 42

    def test_parses(self, monkeypatch):
        monkeypatch.setenv("FOO", "100")
        assert _env_int("FOO", default=42) == 100

    def test_non_numeric_raises(self, monkeypatch):
        monkeypatch.setenv("FOO", "abc")
        with pytest.raises(ValueError, match="integer"):
            _env_int("FOO", default=42)

    def test_below_ge_raises(self, monkeypatch):
        monkeypatch.setenv("FOO", "0")
        with pytest.raises(ValueError, match=">="):
            _env_int("FOO", default=42, ge=1)

    def test_above_le_raises(self, monkeypatch):
        monkeypatch.setenv("FOO", "100")
        with pytest.raises(ValueError, match="<="):
            _env_int("FOO", default=42, le=99)

    def test_ge_le_default_validated(self, monkeypatch):
        """A bad default also raises — protects against bad code defaults."""
        monkeypatch.delenv("FOO", raising=False)
        with pytest.raises(ValueError, match=">="):
            _env_int("FOO", default=0, ge=1)


class TestEnvFloat:
    def test_default(self, monkeypatch):
        monkeypatch.delenv("FOO", raising=False)
        assert _env_float("FOO", default=1.5) == 1.5

    def test_parses(self, monkeypatch):
        monkeypatch.setenv("FOO", "2.5")
        assert _env_float("FOO", default=1.5) == 2.5

    def test_non_numeric_raises(self, monkeypatch):
        monkeypatch.setenv("FOO", "not-a-number")
        with pytest.raises(ValueError, match="float"):
            _env_float("FOO", default=1.5)

    def test_gt_strict(self, monkeypatch):
        monkeypatch.setenv("FOO", "0")
        with pytest.raises(ValueError, match=">"):
            _env_float("FOO", default=1.5, gt=0)

    def test_range_inclusive(self, monkeypatch):
        monkeypatch.setenv("FOO", "1.0")
        assert _env_float("FOO", default=0.5, ge=0.0, le=1.0) == 1.0
        monkeypatch.setenv("FOO", "1.01")
        with pytest.raises(ValueError, match="<="):
            _env_float("FOO", default=0.5, ge=0.0, le=1.0)


# ── Loader integration ────────────────────────────────────────────────────


class TestLoadConfig:
    def test_requires_auth_token(self, monkeypatch):
        monkeypatch.delenv("AUTH_TOKEN", raising=False)
        with pytest.raises(ValueError, match="AUTH_TOKEN"):
            load_config()

    def test_minimal_config_uses_defaults(self, monkeypatch):
        monkeypatch.setenv("AUTH_TOKEN", "tok")
        # Clear any env vars that might leak in from .env
        for k in [
            "SERVER_HOST", "SERVER_PORT", "OLLAMA_URL", "OLLAMA_MODEL",
            "VIBEVOICE_URL", "TTS_VOICE", "TTS_SPEED", "TTS_SAMPLE_RATE",
            "VAD_SPEECH_THRESHOLD", "HF_SILENCE_MS", "HF_MAX_LISTEN_SECS",
            "HF_MIN_AUDIO_BYTES", "HF_SMART_TURN_THRESHOLD",
        ]:
            monkeypatch.delenv(k, raising=False)
        cfg = load_config()
        assert cfg.server.auth_token == "tok"
        assert cfg.server.port == 8001
        assert cfg.tts.speed == 1.3
        assert cfg.vad.speech_threshold == 0.5
        assert cfg.hands_free.silence_ms == 700

    def test_invalid_port_rejected(self, monkeypatch):
        monkeypatch.setenv("AUTH_TOKEN", "tok")
        monkeypatch.setenv("SERVER_PORT", "0")
        with pytest.raises(ValueError, match="SERVER_PORT"):
            load_config()

    def test_invalid_speech_threshold_rejected(self, monkeypatch):
        monkeypatch.setenv("AUTH_TOKEN", "tok")
        monkeypatch.setenv("VAD_SPEECH_THRESHOLD", "1.5")
        with pytest.raises(ValueError, match="VAD_SPEECH_THRESHOLD"):
            load_config()

    def test_invalid_tts_speed_rejected(self, monkeypatch):
        monkeypatch.setenv("AUTH_TOKEN", "tok")
        monkeypatch.setenv("TTS_SPEED", "0")
        with pytest.raises(ValueError, match="TTS_SPEED"):
            load_config()

    def test_env_overrides_apply(self, monkeypatch):
        monkeypatch.setenv("AUTH_TOKEN", "tok")
        monkeypatch.setenv("SERVER_PORT", "9090")
        monkeypatch.setenv("OLLAMA_MODEL", "custom-model")
        monkeypatch.setenv("HF_SILENCE_MS", "500")
        cfg = load_config()
        assert cfg.server.port == 9090
        assert cfg.ollama.model == "custom-model"
        assert cfg.hands_free.silence_ms == 500
