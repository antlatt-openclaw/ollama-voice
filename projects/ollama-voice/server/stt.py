"""Groq Whisper STT integration."""

import asyncio
import io
import logging
import httpx
from audio import pcm_to_wav
from config import STTConfig

log = logging.getLogger("stt")

MAX_RETRIES = 2


async def transcribe(audio_data: bytes, cfg: STTConfig, input_sample_rate: int = 16000, language: str = "en") -> str | None:
    """Transcribe PCM audio using Groq Whisper API."""
    if not cfg.groq_api_key:
        log.warning("No Groq API key configured")
        return None

    wav_data = pcm_to_wav(audio_data, sample_rate=input_sample_rate)
    log.info("Sending %d PCM bytes (%d WAV bytes) to Groq", len(audio_data), len(wav_data))

    for attempt in range(MAX_RETRIES + 1):
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
                        "language": language,
                    },
                )
                log.debug("Response status: %d", response.status_code)
                response.raise_for_status()
                result = response.json()
                text = result.get("text", "").strip()
                log.info("Transcript: '%.80s'", text) if text else log.debug("Empty transcript returned")
                return text if text else None
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 429 and attempt < MAX_RETRIES:
                wait = 2 ** attempt
                log.warning("Groq rate limited (attempt %d/%d), retrying in %ds...",
                            attempt + 1, MAX_RETRIES + 1, wait)
                await asyncio.sleep(wait)
                continue
            log.error("Groq Whisper error: %s", e)
            return None
        except Exception as e:
            log.error("Groq Whisper error: %s", e)
            return None
    return None