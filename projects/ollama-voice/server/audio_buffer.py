"""Per-session PCM ring buffer for PTT mode."""

import logging

log = logging.getLogger("server")

# Maximum bytes the per-session audio buffer will hold (~30 s at 16 kHz/16-bit mono).
AUDIO_BUFFER_MAX_BYTES = 960_000


class AudioBuffer:
    """Per-session PCM ring buffer for PTT mode.

    Keeps at most AUDIO_BUFFER_MAX_BYTES; drops oldest audio on overflow.
    """

    def __init__(self):
        self._buf = bytearray()

    def add(self, pcm_bytes: bytes):
        self._buf.extend(pcm_bytes)
        if len(self._buf) > AUDIO_BUFFER_MAX_BYTES:
            excess = len(self._buf) - AUDIO_BUFFER_MAX_BYTES
            del self._buf[:excess]
            log.warning("AudioBuffer overflow, dropped %d bytes of oldest audio", excess)

    def take(self) -> bytes:
        data = bytes(self._buf)
        self._buf = bytearray()
        return data

    def __len__(self) -> int:
        return len(self._buf)
