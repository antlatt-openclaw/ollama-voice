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

# Maximum characters to pass to TTS in a single request.
MAX_TTS_CHARS = 4000


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
    if len(text) > MAX_TTS_CHARS:
        log.warning("TTS text too long (%d chars), truncating to %d", len(text), MAX_TTS_CHARS)
        text = text[:MAX_TTS_CHARS]
    clean = _clean_text(text)
    if not clean:
        log.warning("TTS text empty after cleaning, skipping synthesis")
        return None

    log.info("TTS synthesizing %d chars (voice=%s, speed=%.1f)", len(clean), cfg.voice, cfg.speed)

    result = await _vibevoice(clean, cfg)
    if result is not None:
        log.info("VibeVoice TTS success: %d bytes PCM", len(result))
        return result
    log.warning("VibeVoice returned None, trying Kokoro fallback")

    result = await _kokoro(clean, cfg)
    if result is not None:
        log.info("Kokoro fallback TTS success: %d bytes PCM", len(result))
        return result
    log.warning("Kokoro returned None, trying Qwen3 fallback")

    result = await _qwen3(clean, cfg)
    if result is not None:
        log.info("Qwen3 fallback TTS success: %d bytes PCM", len(result))
    else:
        log.error("All TTS providers failed (VibeVoice → Kokoro → Qwen3)")
    return result


async def _vibevoice(text: str, cfg: TTSConfig) -> bytes | None:
    """VibeVoice via Gradio queue API (fn_index=3, generate_podcast_wrapper)."""
    script = f"Speaker 1: {text}"
    sp = cfg.voice

    for attempt in range(MAX_RETRIES + 1):
        session_hash = uuid.uuid4().hex[:12]
        join_payload = {
            "fn_index": 3,
            "data": [1.0, script, sp, sp, sp, sp, float(cfg.speed)],
            "session_hash": session_hash,
        }

        try:
            async with httpx.AsyncClient(timeout=300.0) as client:
                # Step 1: Join the generation queue
                resp = await client.post(
                    f"{cfg.vibevoice_url}/gradio_api/queue/join",
                    json=join_payload,
                )
                resp.raise_for_status()
                join_data = resp.json()
                event_id = join_data.get("event_id")
                if not event_id:
                    log.warning("VibeVoice: no event_id in join response (resp=%s)", join_data)
                    if not join_data.get("success", True):
                        log.error("VibeVoice queue join failed: %s", join_data.get("error", "Unknown error"))
                    return None
                log.info("VibeVoice queue joined (event_id=%s, attempt=%d/%d)",
                         event_id, attempt + 1, MAX_RETRIES + 1)

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

                        msg_type = msg.get("msg")
                        event_id_msg = msg.get("event_id")
                        if msg_type == "estimation":
                            log.info("VibeVoice: queue rank=%s, eta=%.1fs",
                                     msg.get("rank"), msg.get("rank_eta", 0))
                            continue
                        if msg_type == "process_starts":
                            log.info("VibeVoice: generation started (event_id=%s)", event_id_msg)
                            continue
                        if msg_type == "process_generating":
                            log.debug("VibeVoice: generating...")
                            continue
                        if msg_type != "process_completed":
                            continue

                        if event_id_msg is not None and event_id_msg != event_id:
                            log.warning("VibeVoice: event_id mismatch (expected=%s, got=%s)",
                                        event_id, event_id_msg)
                            continue

                        if not msg.get("success", True):
                            log.error("VibeVoice generation failed: %s", msg.get("error", "Unknown error"))
                            return None

                        # Gradio returns output as a dict with 'data' key, but guard against list form too
                        output = msg.get("output", {})
                        if isinstance(output, list):
                            out_data = output
                        else:
                            out_data = output.get("data", [])

                        # Returns: [streaming_file, podcast_file, log, value]
                        podcast_info = out_data[1] if len(out_data) > 1 else None

                        # Unwrap {"__type__": "update", "value": {...}}
                        if isinstance(podcast_info, dict) and podcast_info.get("__type__") == "update":
                            podcast_info = podcast_info.get("value")

                        if not (podcast_info and isinstance(podcast_info, dict)):
                            log.warning("VibeVoice: no podcast file in response (out_data=%s)", out_data)
                            return None

                        file_url = podcast_info.get("url", "")
                        if not file_url:
                            log.warning("VibeVoice: podcast file has no URL (podcast_info=%s)", podcast_info)
                            return None
                        if file_url.startswith("/"):
                            file_url = f"{cfg.vibevoice_url}{file_url}"

                        log.info("VibeVoice: downloading audio from %s", file_url)
                        audio_resp = await client.get(file_url)
                        audio_resp.raise_for_status()
                        pcm = await _audio_to_pcm(audio_resp.content, target_rate=cfg.output_sample_rate)
                        if pcm:
                            log.info("VibeVoice: synthesized %d bytes PCM (%.2fs @ %dHz)",
                                     len(pcm),
                                     len(pcm) / (cfg.output_sample_rate * 2),
                                     cfg.output_sample_rate)
                        return pcm

        except httpx.HTTPStatusError as e:
            if e.response.status_code in (429, 502, 503, 504) and attempt < MAX_RETRIES:
                wait = 2 ** attempt
                log.warning("VibeVoice HTTP %d (attempt %d/%d), retrying in %ds...",
                            e.response.status_code, attempt + 1, MAX_RETRIES + 1, wait)
                await asyncio.sleep(wait)
                continue
            log.error("VibeVoice HTTP error: %s", e)
            return None
        except (httpx.ConnectError, httpx.TimeoutException, httpx.NetworkError) as e:
            if attempt < MAX_RETRIES:
                wait = 2 ** attempt
                log.warning("VibeVoice connection error (attempt %d/%d), retrying in %ds...: %s",
                            attempt + 1, MAX_RETRIES + 1, wait, e)
                await asyncio.sleep(wait)
                continue
            log.error("VibeVoice connection failed after %d attempts: %s", MAX_RETRIES + 1, e)
            return None
        except Exception as e:
            log.error("VibeVoice unexpected error: %s", e, exc_info=True)
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
            pcm = await _audio_to_pcm(resp.content, target_rate=cfg.output_sample_rate)
            if pcm:
                log.info("Kokoro fallback: synthesized %d bytes PCM", len(pcm))
            return pcm
    except httpx.HTTPStatusError as e:
        log.error("Kokoro HTTP %d error: %s", e.response.status_code, e)
        return None
    except (httpx.ConnectError, httpx.TimeoutException, httpx.NetworkError) as e:
        log.error("Kokoro connection error: %s", e)
        return None
    except Exception as e:
        log.error("Kokoro unexpected error: %s", e)
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
            pcm = await _audio_to_pcm(resp.content, target_rate=cfg.output_sample_rate)
            if pcm:
                log.info("Qwen3 fallback: synthesized %d bytes PCM", len(pcm))
            return pcm
    except httpx.HTTPStatusError as e:
        log.error("Qwen3 HTTP %d error: %s", e.response.status_code, e)
        return None
    except (httpx.ConnectError, httpx.TimeoutException, httpx.NetworkError) as e:
        log.error("Qwen3 connection error: %s", e)
        return None
    except Exception as e:
        log.error("Qwen3 unexpected error: %s", e)
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
    except Exception as e:
        log.error("ffmpeg error: %s", e)

    return None