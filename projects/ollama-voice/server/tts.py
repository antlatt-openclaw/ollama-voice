"""TTS integration — VibeVoice primary, Kokoro/Qwen3 fallback."""

import asyncio
import json
import logging
import re
import uuid
import httpx
import struct
from config import TTSConfig

log = logging.getLogger("tts")

MAX_RETRIES = 2


def _clean_text(text: str) -> str:
    """Strip markdown and normalize punctuation for TTS synthesis."""
    clean = text
    clean = re.sub(r'\*{1,3}(.*?)\*{1,3}', r'\1', clean)
    clean = re.sub(r'_{1,2}(.*?)_{1,2}', r'\1', clean)
    clean = re.sub(r'`{1,3}[^`]*`{1,3}', '', clean)
    clean = re.sub(r'^#{1,6}\s*', '', clean, flags=re.MULTILINE)
    clean = re.sub(r'^\s*[-*+]\s+', '', clean, flags=re.MULTILINE)
    clean = re.sub(r'^\s*\d+\.\s+', '', clean, flags=re.MULTILINE)
    clean = re.sub(r'—', ', ', clean)
    clean = re.sub(r'–', ', ', clean)
    clean = re.sub(r'\.{2,}', '.', clean)
    clean = re.sub(r'\(([^)]*)\)', r'\1', clean)
    clean = re.sub(r'\[([^\]]*)\]', r'\1', clean)
    clean = re.sub(r'[\u2018\u2019]', "'", clean)
    clean = re.sub(r'[\u201c\u201d]', '"', clean)
    # Remove control characters but keep all other Unicode (letters, accents, CJK, etc.)
    clean = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', clean)
    return re.sub(r'\s+', ' ', clean).strip()


async def synthesize(text: str, cfg: TTSConfig) -> bytes | None:
    """Synthesize speech — VibeVoice primary, Kokoro/Qwen3 fallback.

    Returns cfg.output_sample_rate Hz 16-bit mono PCM bytes, or None on failure.
    """
    clean = _clean_text(text)
    if not clean:
        return None

    try:
        result = await _vibevoice(clean, cfg)
        if result is not None:
            return result
    except Exception as e:
        log.error("VibeVoice failed, trying fallback: %s", e)

    try:
        result = await _kokoro(clean, cfg)
        if result is not None:
            return result
    except Exception as e:
        log.error("Kokoro failed, trying fallback: %s", e)

    try:
        return await _qwen3(clean, cfg)
    except Exception as e:
        log.error("Qwen3 fallback also failed: %s", e)
        return None


async def _vibevoice(text: str, cfg: TTSConfig) -> bytes | None:
    """VibeVoice via Gradio queue API (fn_index=3, generate_podcast_wrapper)."""
    script = f"Speaker 1: {text}"
    session_hash = uuid.uuid4().hex[:10]
    sp = cfg.voice

    join_payload = {
        "fn_index": 3,
        "data": [1, script, sp, sp, sp, sp, cfg.speed],
        "session_hash": session_hash,
    }

    for attempt in range(MAX_RETRIES + 1):
        try:
            async with httpx.AsyncClient(timeout=300.0) as client:
                # Step 1: Join the generation queue
                resp = await client.post(
                    f"{cfg.vibevoice_url}/gradio_api/queue/join",
                    json=join_payload,
                )
                resp.raise_for_status()
                if not resp.json().get("event_id"):
                    log.warning("VibeVoice: no event_id in join response")
                    return None

                # Step 2: Stream SSE until process_completed
                async with client.stream(
                    "GET",
                    f"{cfg.vibevoice_url}/gradio_api/queue/data",
                    params={"session_hash": session_hash},
                ) as sse:
                    sse.raise_for_status()
                    async for line in sse.aiter_lines():
                        if not line.startswith("data: "):
                            continue
                        try:
                            msg = json.loads(line[6:])
                        except json.JSONDecodeError:
                            continue

                        if msg.get("msg") != "process_completed":
                            continue

                        out_data = msg.get("output", {}).get("data", [])
                        # Returns: [streaming_file, podcast_file, log, value]
                        podcast_info = out_data[1] if len(out_data) > 1 else None

                        # Unwrap {"__type__": "update", "value": {...}}
                        if isinstance(podcast_info, dict) and podcast_info.get("__type__") == "update":
                            podcast_info = podcast_info.get("value")

                        if not (podcast_info and isinstance(podcast_info, dict)):
                            log.warning("VibeVoice: no podcast file in response")
                            return None

                        file_url = podcast_info.get("url", "")
                        if not file_url:
                            return None
                        if file_url.startswith("/"):
                            file_url = f"{cfg.vibevoice_url}{file_url}"

                        audio_resp = await client.get(file_url)
                        audio_resp.raise_for_status()
                        return await _audio_to_pcm(audio_resp.content, target_rate=cfg.output_sample_rate)

        except httpx.HTTPStatusError as e:
            if e.response.status_code in (429, 502, 503, 504) and attempt < MAX_RETRIES:
                wait = 2 ** attempt
                log.warning("VibeVoice error %d (attempt %d/%d), retrying in %ds...",
                            e.response.status_code, attempt + 1, MAX_RETRIES + 1, wait)
                await asyncio.sleep(wait)
                continue
            log.error("VibeVoice error: %s", e)
            return None
        except Exception as e:
            log.error("VibeVoice error: %s", e)
            return None
    return None


async def _kokoro(text: str, cfg: TTSConfig) -> bytes | None:
    """Kokoro TTS — OpenAI-compatible API."""
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                f"{cfg.fallback_kokoro_url}/v1/audio/speech",
                json={
                    "model": "kokoro",
                    "input": text,
                    "voice": cfg.fallback_kokoro_voice,
                    "response_format": "wav",
                },
            )
            resp.raise_for_status()
            return await _audio_to_pcm(resp.content, target_rate=cfg.output_sample_rate)
    except Exception as e:
        log.error("Kokoro error: %s", e)
        return None


async def _qwen3(text: str, cfg: TTSConfig) -> bytes | None:
    """Qwen3-TTS fallback."""
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                f"{cfg.fallback_qwen3_url}/v1/audio/speech",
                json={
                    "model": "qwen3-tts",
                    "input": text,
                    "voice": cfg.fallback_qwen3_voice,
                    "response_format": "wav",
                },
            )
            resp.raise_for_status()
            return await _audio_to_pcm(resp.content, target_rate=cfg.output_sample_rate)
    except Exception as e:
        log.error("Qwen3 error: %s", e)
        return None


def _find_wav_data_chunk(audio_data: bytes) -> tuple[int, int] | None:
    """Scan a WAV file for the 'data' sub-chunk, returning (offset, size).

    Standard minimal WAV puts the data chunk at byte 44, but files with
    extra chunks (fact, LIST, etc.) push it further. This scans rather
    than assuming a fixed offset so those files are handled correctly.
    """
    offset = 12  # skip RIFF(4) + file-size(4) + WAVE(4)
    while offset + 8 <= len(audio_data):
        chunk_id = audio_data[offset:offset + 4]
        chunk_size = struct.unpack_from('<I', audio_data, offset + 4)[0]
        if chunk_id == b'data':
            return offset + 8, chunk_size
        # Guard against zero/invalid chunk_size to prevent infinite loop
        if chunk_size <= 0:
            offset += 9  # advance past this header with minimum stride
        else:
            offset += 8 + chunk_size
    return None


async def _audio_to_pcm(audio_data: bytes, target_rate: int = 24000) -> bytes | None:
    """Convert audio data (any format) to raw 16-bit mono PCM at target rate.

    Fast path: if the input is already a PCM WAV at the right rate, extract
    the raw samples directly without spawning ffmpeg.
    General path: decode via ffmpeg (handles WAV, OGG, MP3, Opus, etc.).
    The ffmpeg call is async so it does not block the event loop.
    """
    # Fast path: PCM-only WAV at the right sample rate
    if audio_data[:4] == b'RIFF' and len(audio_data) >= 44:
        channels = struct.unpack_from('<H', audio_data, 22)[0]
        sample_rate = struct.unpack_from('<I', audio_data, 24)[0]
        bits = struct.unpack_from('<H', audio_data, 34)[0]
        if channels == 1 and sample_rate == target_rate and bits == 16:
            result = _find_wav_data_chunk(audio_data)
            if result is not None:
                data_offset, data_size = result
                return audio_data[data_offset:data_offset + data_size]

    # General path: decode via ffmpeg without blocking the event loop
    try:
        proc = await asyncio.create_subprocess_exec(
            'ffmpeg', '-hide_banner', '-loglevel', 'error',
            '-i', 'pipe:0',
            '-f', 's16le',
            '-ar', str(target_rate),
            '-ac', '1',
            'pipe:1',
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(input=audio_data), timeout=30
            )
        except asyncio.TimeoutError:
            log.error("ffmpeg timed out, killing process")
            try:
                proc.kill()
                await proc.wait()
            except Exception:
                pass
            return None
        if proc.returncode == 0 and stdout:
            log.info("ffmpeg decoded %d bytes → %d PCM bytes", len(audio_data), len(stdout))
            return stdout
        log.warning("ffmpeg decode failed (rc=%d): %s", proc.returncode, stderr.decode()[:200])
    except asyncio.TimeoutError:
        log.error("ffmpeg timed out")
    except Exception as e:
        log.error("ffmpeg error: %s", e)

    return None