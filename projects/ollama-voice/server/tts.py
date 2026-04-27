"""TTS integration — provider-based fallback chain.

Default chain: VibeVoice (primary, gradio_client) → Kokoro → Qwen3
(both OpenAI-compatible /v1/audio/speech backends).
"""

import asyncio
import logging
import re
import struct
from dataclasses import dataclass
from typing import Protocol
import httpx
from config import TTSConfig

log = logging.getLogger("tts")

# Maximum characters to pass to TTS in a single request.
MAX_TTS_CHARS = 4000
# Per-attempt timeout for the VibeVoice gradio call. The Gradio server itself
# may queue, but we don't want to block a user for minutes if it's stuck.
VIBEVOICE_TIMEOUT_S = 90.0


# ── Provider protocol ────────────────────────────────────────────────────


class TTSProvider(Protocol):
    name: str

    async def synthesize(self, text: str, cfg: TTSConfig) -> bytes | None: ...


# ── VibeVoice (primary) ──────────────────────────────────────────────────


class VibeVoiceProvider:
    name = "VibeVoice"

    async def synthesize(self, text: str, cfg: TTSConfig) -> bytes | None:
        try:
            from gradio_client import Client
        except ImportError:
            log.error("gradio_client not installed; cannot reach VibeVoice")
            return None

        script = f"Speaker 1: {text}"
        sp = cfg.voice

        def _call_gradio() -> str | None:
            # download_files=False so gradio_client doesn't try to fetch the
            # streaming .m3u8 at output[0] (VibeVoice 403s those). We extract
            # only output[1] (the final podcast file) and fetch it ourselves.
            client = Client(cfg.vibevoice_url, verbose=False, download_files=False)
            result = client.predict(
                1.0, script, sp, sp, sp, sp, float(cfg.speed),
                api_name=None, fn_index=3,
            )
            # Output shape: [streaming_file, podcast_update, log, value]
            # The podcast slot is wrapped in {'visible': True, 'value': {...}}
            # (or {'__type__': 'update', 'value': {...}} on some Gradio versions),
            # so we unwrap before reading url/path.
            podcast = result[1] if isinstance(result, (list, tuple)) and len(result) > 1 else None
            if isinstance(podcast, dict):
                direct = podcast.get("url") or podcast.get("path")
                if direct:
                    return direct
                inner = podcast.get("value")
                if isinstance(inner, dict):
                    return inner.get("url") or inner.get("path")
                if isinstance(inner, str):
                    return inner
            if isinstance(podcast, (list, tuple)) and podcast:
                return podcast[0]
            if isinstance(podcast, str):
                return podcast
            return None

        try:
            loop = asyncio.get_running_loop()
            path = await asyncio.wait_for(
                loop.run_in_executor(None, _call_gradio),
                timeout=VIBEVOICE_TIMEOUT_S,
            )
        except asyncio.TimeoutError:
            log.error("VibeVoice timeout after %.0fs", VIBEVOICE_TIMEOUT_S)
            return None
        except Exception as e:
            log.error("VibeVoice gradio_client error: %s", e)
            return None

        if not path:
            log.warning("VibeVoice returned no file path")
            return None

        audio_bytes = await _read_audio(path, cfg.vibevoice_url)
        if audio_bytes is None:
            return None

        pcm = await _audio_to_pcm(audio_bytes, target_rate=cfg.output_sample_rate)
        if pcm:
            log.info("VibeVoice: %d bytes PCM (%.2fs @ %dHz)",
                     len(pcm), len(pcm) / (cfg.output_sample_rate * 2), cfg.output_sample_rate)
        return pcm


# ── OpenAI-compatible /v1/audio/speech (Kokoro, Qwen3, etc.) ─────────────


@dataclass
class OpenAICompatProvider:
    """Generic /v1/audio/speech client. One instance per backend (Kokoro, Qwen3, ...)."""
    name: str
    base_url: str
    model: str
    voice: str
    timeout: float = 60.0

    async def synthesize(self, text: str, cfg: TTSConfig) -> bytes | None:
        url = f"{self.base_url}/v1/audio/speech"
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                resp = await client.post(
                    url,
                    json={"model": self.model, "input": text, "voice": self.voice, "response_format": "wav"},
                )
                resp.raise_for_status()
                return await _audio_to_pcm(resp.content, target_rate=cfg.output_sample_rate)
        except httpx.HTTPStatusError as e:
            log.error("%s HTTP %d: %s", self.name, e.response.status_code, e)
        except (httpx.ConnectError, httpx.TimeoutException, httpx.NetworkError) as e:
            log.error("%s connection error: %s", self.name, e)
        except Exception as e:
            log.error("%s unexpected error: %s", self.name, e)
        return None


def default_providers(cfg: TTSConfig) -> list[TTSProvider]:
    """Default fallback chain built from cfg."""
    return [
        VibeVoiceProvider(),
        OpenAICompatProvider(
            name="Kokoro",
            base_url=cfg.fallback_kokoro_url,
            model="kokoro",
            voice=cfg.fallback_kokoro_voice,
        ),
        OpenAICompatProvider(
            name="Qwen3",
            base_url=cfg.fallback_qwen3_url,
            model="qwen3-tts",
            voice=cfg.fallback_qwen3_voice,
        ),
    ]


# ── Public entry point ───────────────────────────────────────────────────


async def synthesize(
    text: str,
    cfg: TTSConfig,
    providers: list[TTSProvider] | None = None,
) -> bytes | None:
    """Synthesize speech via the provider chain. First non-None result wins.

    Returns cfg.output_sample_rate Hz 16-bit mono PCM bytes, or None on failure.
    Pass `providers=` to inject a custom chain (e.g. for tests).
    """
    if providers is None:
        providers = default_providers(cfg)

    if len(text) > MAX_TTS_CHARS:
        log.warning("TTS text too long (%d chars), truncating to %d", len(text), MAX_TTS_CHARS)
        text = text[:MAX_TTS_CHARS]
    clean = _clean_text(text)
    if not clean:
        log.warning("TTS text empty after cleaning, skipping")
        return None

    log.info("TTS synthesizing %d chars (voice=%s, speed=%.1f)", len(clean), cfg.voice, cfg.speed)

    for provider in providers:
        result = await provider.synthesize(clean, cfg)
        if result is not None:
            log.info("%s TTS success: %d bytes PCM", provider.name, len(result))
            return result
        log.warning("%s returned None, trying next fallback", provider.name)

    log.error("All TTS providers failed")
    return None


# ── Helpers ──────────────────────────────────────────────────────────────


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
    clean = re.sub(r'[‘’]', "'", clean)
    clean = re.sub(r'[“”]', '"', clean)
    clean = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', clean)
    return re.sub(r'\s+', ' ', clean).strip()


async def _read_audio(path_or_url: str, server_url: str) -> bytes | None:
    """Read audio bytes from a local file path (gradio_client downloads it)
    or, if it's an HTTP URL, fetch it directly."""
    if path_or_url.startswith(("http://", "https://")):
        url = path_or_url
    elif path_or_url.startswith("/"):
        # Gradio relative path
        url = f"{server_url.rstrip('/')}{path_or_url}"
    else:
        # Local downloaded path
        try:
            with open(path_or_url, "rb") as f:
                return f.read()
        except Exception as e:
            log.error("Failed to read VibeVoice file %s: %s", path_or_url, e)
            return None

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            return resp.content
    except Exception as e:
        log.error("Failed to fetch VibeVoice audio from %s: %s", url, e)
        return None


def _find_wav_data_chunk(audio_data: bytes) -> tuple[int, int] | None:
    """Scan a WAV file for the 'data' sub-chunk, returning (offset, size)."""
    offset = 12
    while offset + 8 <= len(audio_data):
        chunk_id = audio_data[offset:offset + 4]
        chunk_size = struct.unpack_from('<I', audio_data, offset + 4)[0]
        if chunk_id == b'data':
            return offset + 8, chunk_size
        if chunk_size <= 0:
            offset += 9
        else:
            offset += 8 + chunk_size
    return None


async def _audio_to_pcm(audio_data: bytes, target_rate: int = 24000) -> bytes | None:
    """Convert audio (any format) to raw 16-bit mono PCM at target rate."""
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

    try:
        proc = await asyncio.create_subprocess_exec(
            'ffmpeg', '-hide_banner', '-loglevel', 'error',
            '-i', 'pipe:0', '-f', 's16le', '-ar', str(target_rate), '-ac', '1', 'pipe:1',
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(input=audio_data), timeout=30
            )
        except asyncio.TimeoutError:
            log.error("ffmpeg timed out")
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
