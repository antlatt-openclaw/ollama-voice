"""Audio utilities — VAD classifier, per-session audio buffer, end-of-turn detector, format helpers."""

import asyncio
import logging
import struct
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
# Maximum bytes the per-session audio buffer will hold (~30 s at 16 kHz/16-bit mono).
AUDIO_BUFFER_MAX_BYTES = 960_000


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


def wav_header(data_length: int, sample_rate: int, channels: int = 1, bits: int = 16) -> bytes:
    byte_rate = sample_rate * channels * bits // 8
    block_align = channels * bits // 8
    return struct.pack(
        '<4sI4s4sIHHIIHH4sI',
        b'RIFF', data_length + 36, b'WAVE',
        b'fmt ', 16, 1, channels, sample_rate, byte_rate, block_align, bits,
        b'data', data_length,
    )


def pcm_to_wav(pcm_data: bytes, sample_rate: int, channels: int = 1, bits: int = 16) -> bytes:
    return wav_header(len(pcm_data), sample_rate, channels, bits) + pcm_data


class SmartTurnDetector:
    """End-of-turn classifier (pipecat smart-turn-v3.2 ONNX). Lazy-loaded.

    Falls back to 1.0 (always complete) if the model is unavailable.
    """

    _MODEL_URL = (
        "https://huggingface.co/pipecat-ai/smart-turn-v3/resolve/main"
        "/smart-turn-v3.2-cpu.onnx"
    )
    _SAMPLE_RATE = 16000
    _MAX_SAMPLES = 8 * _SAMPLE_RATE  # clamp input to last 8 s

    def __init__(self):
        self._session = None
        self._extractor = None
        self._available = False
        self._load_lock = asyncio.Lock()

    @property
    def loaded(self) -> bool:
        return self._available

    async def ensure_loaded(self):
        if self._available:
            return
        async with self._load_lock:
            if self._available:
                return
            await asyncio.get_running_loop().run_in_executor(None, self._load_sync)

    def _load_sync(self):
        try:
            import os
            import onnxruntime as ort
            from transformers import WhisperFeatureExtractor

            model_dir = os.path.join(os.path.expanduser("~"), ".cache", "smartturn")
            model_path = os.path.join(model_dir, "smart_turn_v3.2_cpu.onnx")

            if not os.path.exists(model_path):
                log.info("[SmartTurn] Downloading Smart Turn v3.2 model (~30 MB)...")
                os.makedirs(model_dir, exist_ok=True)
                import httpx
                with httpx.Client(timeout=60.0) as http_client:
                    resp = http_client.get(self._MODEL_URL)
                    resp.raise_for_status()
                    with open(model_path, "wb") as f:
                        f.write(resp.content)

            self._session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
            self._extractor = WhisperFeatureExtractor.from_pretrained("openai/whisper-tiny")
            self._available = True
            log.info("Audio model loaded (pipecat smart-turn-v3.2)")
        except Exception as e:
            log.warning("Could not load SmartTurn model (%s); falling back to silence-only detection", e)

    def _predict_sync(self, audio_bytes: bytes) -> float:
        try:
            samples = np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32) / 32768.0
            samples = samples[-self._MAX_SAMPLES:]
            features = self._extractor(
                samples,
                sampling_rate=self._SAMPLE_RATE,
                max_length=self._MAX_SAMPLES,
                padding="max_length",
                return_attention_mask=False,
                return_tensors="np",
            )
            prob = float(
                self._session.run(
                    None,
                    {"input_features": features.input_features.astype(np.float32)},
                )[0].flatten()[0]
            )
            log.debug("turn_prob=%.3f", prob)
            return prob
        except Exception as e:
            log.warning("SmartTurn inference error: %s", e)
            return 1.0

    async def predict(self, audio_bytes: bytes) -> float:
        if not self._available or not audio_bytes:
            return 1.0
        return await asyncio.get_running_loop().run_in_executor(
            None, self._predict_sync, audio_bytes
        )
