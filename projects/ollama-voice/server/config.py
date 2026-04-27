"""Configuration for ollama-voice server."""

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")


@dataclass
class ServerConfig:
    host: str = "0.0.0.0"
    port: int = 8001
    auth_token: str = ""
    auth_timeout: float = 5.0


@dataclass
class OllamaConfig:
    url: str = "http://localhost:11434/v1/chat/completions"
    model: str = "huihui_ai/gemma-4-abliterated:e4b"
    timeout: float = 120.0


@dataclass
class HandsFreeConfig:
    """Tuning knobs for the hands-free (VAD) turn detector."""
    silence_ms: int = 700           # How long silence must last to end a turn
    max_listen_secs: int = 15      # Hard cap on single turn length
    min_audio_bytes: int = 8000    # Discard turns shorter than this
    smart_turn_threshold: float = 0.5  # SmartTurn probability below this = keep listening


@dataclass
class VADConfig:
    speech_threshold: float = 0.5
    window_size_samples: int = 512


@dataclass
class STTConfig:
    groq_api_key: str = ""
    model: str = "whisper-large-v3-turbo"


@dataclass
class TTSConfig:
    vibevoice_url: str = "http://192.168.1.210:7860"
    voice: str = "custom-Beatrice-2"
    speed: float = 1.3
    output_sample_rate: int = 24000
    fallback_kokoro_url: str = "http://192.168.1.204:8880"
    fallback_kokoro_voice: str = "af_nova"
    fallback_qwen3_url: str = "http://192.168.1.204:8881"
    fallback_qwen3_voice: str = "default"


@dataclass
class AudioConfig:
    input_sample_rate: int = 16000


@dataclass
class Config:
    server: ServerConfig = field(default_factory=ServerConfig)
    ollama: OllamaConfig = field(default_factory=OllamaConfig)
    vad: VADConfig = field(default_factory=VADConfig)
    hands_free: HandsFreeConfig = field(default_factory=HandsFreeConfig)
    stt: STTConfig = field(default_factory=STTConfig)
    tts: TTSConfig = field(default_factory=TTSConfig)
    audio: AudioConfig = field(default_factory=AudioConfig)


# ── Env-var helpers ────────────────────────────────────────────────────────


def _env_str(name: str, *, default: str = "", required: bool = False) -> str:
    raw = os.getenv(name)
    if not raw:
        if required:
            raise ValueError(f"{name} env var is required")
        return default
    return raw


def _env_int(name: str, *, default: int, ge: int | None = None, le: int | None = None) -> int:
    raw = os.getenv(name)
    if raw is None:
        v = default
    else:
        try:
            v = int(raw)
        except ValueError:
            raise ValueError(f"{name} must be an integer, got {raw!r}")
    if ge is not None and v < ge:
        raise ValueError(f"{name} must be >= {ge}, got {v}")
    if le is not None and v > le:
        raise ValueError(f"{name} must be <= {le}, got {v}")
    return v


def _env_float(
    name: str, *, default: float,
    gt: float | None = None, ge: float | None = None,
    lt: float | None = None, le: float | None = None,
) -> float:
    raw = os.getenv(name)
    if raw is None:
        v = default
    else:
        try:
            v = float(raw)
        except ValueError:
            raise ValueError(f"{name} must be a float, got {raw!r}")
    if gt is not None and not v > gt:
        raise ValueError(f"{name} must be > {gt}, got {v}")
    if ge is not None and v < ge:
        raise ValueError(f"{name} must be >= {ge}, got {v}")
    if lt is not None and not v < lt:
        raise ValueError(f"{name} must be < {lt}, got {v}")
    if le is not None and v > le:
        raise ValueError(f"{name} must be <= {le}, got {v}")
    return v


# ── Loader ─────────────────────────────────────────────────────────────────


def load_config() -> Config:
    cfg = Config()

    cfg.server.auth_token = _env_str("AUTH_TOKEN", required=True)
    cfg.server.host = _env_str("SERVER_HOST", default=cfg.server.host)
    cfg.server.port = _env_int("SERVER_PORT", default=cfg.server.port, ge=1, le=65535)

    cfg.stt.groq_api_key = _env_str("GROQ_API_KEY", default=cfg.stt.groq_api_key)

    cfg.ollama.url = _env_str("OLLAMA_URL", default=cfg.ollama.url)
    cfg.ollama.model = _env_str("OLLAMA_MODEL", default=cfg.ollama.model)

    cfg.tts.vibevoice_url = _env_str("VIBEVOICE_URL", default=cfg.tts.vibevoice_url)
    cfg.tts.voice = _env_str("TTS_VOICE", default=cfg.tts.voice)
    cfg.tts.speed = _env_float("TTS_SPEED", default=cfg.tts.speed, gt=0)
    cfg.tts.output_sample_rate = _env_int(
        "TTS_SAMPLE_RATE", default=cfg.tts.output_sample_rate, ge=8000, le=192000,
    )
    cfg.tts.fallback_kokoro_url = _env_str("KOKORO_URL", default=cfg.tts.fallback_kokoro_url)
    cfg.tts.fallback_kokoro_voice = _env_str("KOKORO_VOICE", default=cfg.tts.fallback_kokoro_voice)
    cfg.tts.fallback_qwen3_url = _env_str("QWEN3_URL", default=cfg.tts.fallback_qwen3_url)
    cfg.tts.fallback_qwen3_voice = _env_str("QWEN3_VOICE", default=cfg.tts.fallback_qwen3_voice)

    cfg.vad.speech_threshold = _env_float(
        "VAD_SPEECH_THRESHOLD", default=cfg.vad.speech_threshold, ge=0.0, le=1.0,
    )

    cfg.hands_free.silence_ms = _env_int("HF_SILENCE_MS", default=cfg.hands_free.silence_ms)
    cfg.hands_free.max_listen_secs = _env_int("HF_MAX_LISTEN_SECS", default=cfg.hands_free.max_listen_secs)
    cfg.hands_free.min_audio_bytes = _env_int("HF_MIN_AUDIO_BYTES", default=cfg.hands_free.min_audio_bytes)
    cfg.hands_free.smart_turn_threshold = _env_float(
        "HF_SMART_TURN_THRESHOLD", default=cfg.hands_free.smart_turn_threshold, ge=0.0, le=1.0,
    )

    return cfg
