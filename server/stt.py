"""Groq Whisper STT integration."""

import io
import logging
import httpx
from audio import pcm_to_wav
from config import STTConfig

log = logging.getLogger("stt")


async def transcribe(audio_data: bytes, cfg: STTConfig, input_sample_rate: int = 16000) -> str | None:
    """Transcribe PCM audio using Groq Whisper API.

    Args:
        audio_data: Raw PCM 16-bit mono audio bytes at input_sample_rate
        cfg: STT configuration
        input_sample_rate: Sample rate of the PCM data (default 16000)

    Returns:
        Transcribed text or None on failure
    """
    if not cfg.groq_api_key:
        log.warning("No Groq API key configured")
        return None

    wav_data = pcm_to_wav(audio_data, sample_rate=input_sample_rate)
    log.info("Sending %d PCM bytes (%d WAV bytes) to Groq", len(audio_data), len(wav_data))

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                "https://api.groq.com/openai/v1/audio/transcriptions",
                headers={
                    "Authorization": f"Bearer {cfg.groq_api_key}",
                },
                files={
                    "file": ("audio.wav", io.BytesIO(wav_data), "audio/wav"),
                },
                data={
                    "model": cfg.model,
                    "response_format": "json",
                    "language": "en",
                },
            )
            log.debug("Response status: %d", response.status_code)
            response.raise_for_status()
            result = response.json()
            text = result.get("text", "").strip()
            log.info("Transcript: '%.80s'", text) if text else log.debug("Empty transcript returned")
            return text if text else None
    except Exception as e:
        log.error("Groq Whisper error: %s", e)
        return None