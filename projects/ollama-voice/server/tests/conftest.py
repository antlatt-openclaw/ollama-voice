"""Shared test fixtures for ollama-voice server tests."""
import pytest
from unittest.mock import MagicMock, AsyncMock

# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture
def mock_config():
    """Return a minimal mock config dict."""
    return {
        "llm": {
            "model": "qwen3:14b",
            "temperature": 0.7,
            "max_tokens": 512,
        },
        "stt": {
            "provider": "groq",
            "model": "whisper-large-v3",
        },
        "tts": {
            "primary": "vibevoice",
            "fallbacks": ["kokoro", "qwen3"],
        },
        "audio": {
            "sample_rate": 16000,
            "channels": 1,
            "format": "pcm_s16le",
        },
    }


@pytest.fixture
def mock_audio_bytes():
    """Return fake 16-bit PCM audio data (silence)."""
    # 1 second of silence at 16kHz, 16-bit mono = 32000 bytes
    return b"\x00\x00" * 16000


@pytest.fixture
def mock_ws_client():
    """Return a mock WebSocket client for testing."""
    ws = MagicMock()
    ws.accept = AsyncMock()
    ws.receive_text = AsyncMock()
    ws.receive_bytes = AsyncMock()
    ws.send_text = AsyncMock()
    ws.send_bytes = AsyncMock()
    ws.close = AsyncMock()
    return ws


@pytest.fixture
def valid_auth_message():
    """Return a valid auth message dict."""
    return {
        "type": "auth",
        "client_id": "test-client-001",
        "token": "dev-token",
    }


@pytest.fixture
def invalid_auth_message():
    """Return an invalid auth message dict."""
    return {
        "type": "auth",
        "client_id": "test-client-001",
        "token": "wrong-token",
    }


@pytest.fixture
def ptt_start_message():
    """Return a PTT start message dict."""
    return {"type": "ptt_start"}


@pytest.fixture
def ptt_stop_message():
    """Return a PTT stop message dict."""
    return {"type": "ptt_stop"}
