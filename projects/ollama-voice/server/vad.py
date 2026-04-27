"""Silero VAD wrapper + window-padding helper."""

import asyncio
import logging

import numpy as np

try:
    from silero_vad import load_silero_vad
except ImportError:
    load_silero_vad = None

try:
    import torch
except ImportError:
    torch = None

log = logging.getLogger("server")

# Silero VAD requires exactly 512 int16 samples at 16 kHz = 1024 bytes.
VAD_CHUNK_SIZE = 1024
# Slice size for splitting incoming audio frames before VAD.
VAD_SPLIT_SIZE = 1024


def pad_to_vad_window(pcm_bytes: bytes) -> bytes:
    """Pad or truncate a PCM chunk to exactly VAD_CHUNK_SIZE bytes.

    Padding repeats the last sample to avoid a hard zero-silence edge.
    """
    if len(pcm_bytes) == VAD_CHUNK_SIZE:
        return pcm_bytes
    if len(pcm_bytes) > VAD_CHUNK_SIZE:
        return pcm_bytes[:VAD_CHUNK_SIZE]
    last_sample = pcm_bytes[-2:] if len(pcm_bytes) >= 2 else b'\x00\x00'
    short = VAD_CHUNK_SIZE - len(pcm_bytes)
    return pcm_bytes + last_sample * (short // 2) + (b'\x00' * (short % 2))


class VAD:
    """Stateless Silero VAD classifier. Lazy-loads on first ensure_loaded() call."""

    def __init__(self, sample_rate: int):
        self.sample_rate = sample_rate
        self._model = None
        self._load_lock = asyncio.Lock()

    @property
    def loaded(self) -> bool:
        return self._model is not None

    async def ensure_loaded(self):
        if self._model is not None:
            return
        async with self._load_lock:
            if self._model is not None:
                return
            if load_silero_vad is None:
                raise RuntimeError("silero-vad not installed")
            loop = asyncio.get_running_loop()
            self._model = await loop.run_in_executor(None, load_silero_vad)
            log.info("VAD model loaded")

    def get_speech_prob(self, pcm_bytes: bytes) -> float:
        """Return raw speech probability for a single VAD-window chunk."""
        if self._model is None:
            return 0.0
        pcm_bytes = pad_to_vad_window(pcm_bytes)
        try:
            samples_np = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0
            samples = torch.from_numpy(samples_np) if torch is not None else samples_np
            prob = self._model(samples, self.sample_rate)
            return prob.item() if hasattr(prob, 'item') else float(prob)
        except Exception as e:
            log.error("[VAD] get_speech_prob error: %s", e)
            return 0.0
