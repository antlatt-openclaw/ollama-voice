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


def load_config() -> Config:
    cfg = Config()

    cfg.server.auth_token = os.getenv("AUTH_TOKEN", "")
    if not cfg.server.auth_token:
        raise ValueError("AUTH_TOKEN env var is required")
    if host := os.getenv("SERVER_HOST"):
        cfg.server.host = host
    if port := os.getenv("SERVER_PORT"):
        cfg.server.port = int(port)

    cfg.stt.groq_api_key = os.getenv("GROQ_API_KEY", "")

    if url := os.getenv("OLLAMA_URL"):
        cfg.ollama.url = url
    if model := os.getenv("OLLAMA_MODEL"):
        cfg.ollama.model = model

    if url := os.getenv("VIBEVOICE_URL"):
        cfg.tts.vibevoice_url = url
    if voice := os.getenv("TTS_VOICE"):
        cfg.tts.voice = voice
    if speed := os.getenv("TTS_SPEED"):
        cfg.tts.speed = float(speed)
    if rate := os.getenv("TTS_SAMPLE_RATE"):
        cfg.tts.output_sample_rate = int(rate)
    if url := os.getenv("KOKORO_URL"):
        cfg.tts.fallback_kokoro_url = url
    if voice := os.getenv("KOKORO_VOICE"):
        cfg.tts.fallback_kokoro_voice = voice
    # Hands-free overrides
    if v := os.getenv("HF_SILENCE_MS"):
        cfg.hands_free.silence_ms = int(v)
    if v := os.getenv("HF_MAX_LISTEN_SECS"):
        cfg.hands_free.max_listen_secs = int(v)
    if v := os.getenv("HF_MIN_AUDIO_BYTES"):
        cfg.hands_free.min_audio_bytes = int(v)
    if v := os.getenv("HF_SMART_TURN_THRESHOLD"):
        cfg.hands_free.smart_turn_threshold = float(v)

    if url := os.getenv("QWEN3_URL"):
        cfg.tts.fallback_qwen3_url = url
    if voice := os.getenv("QWEN3_VOICE"):
        cfg.tts.fallback_qwen3_voice = voice

    return cfg
