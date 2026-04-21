"""Audio processing utilities — VAD, turn detection, resampling, format conversion."""

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

from config import Config

log = logging.getLogger("server")


class VADProcessor:
    """Silero VAD wrapper for real-time speech detection."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.model = None
        self._audio_buffer = bytearray()

    def load(self):
        if load_silero_vad is None:
            raise RuntimeError("silero-vad not installed")
        self.model = load_silero_vad()

    def get_speech_prob(self, pcm_bytes: bytes) -> float:
        """Run VAD on a single chunk and return raw speech probability (no state changes).

        Silero VAD requires exactly 512 samples at 16 kHz (1024 bytes).
        Chunks that are too short are padded with last sample; chunks that are
        too long are truncated. Only exact 1024-byte chunks are optimal.
        """
        if self.model is None:
            return 0.0
        EXPECTED_BYTES = 1024  # 512 int16 samples
        if len(pcm_bytes) < EXPECTED_BYTES:
            # Pad with last sample value to avoid zero-silence artifacts
            last_sample = pcm_bytes[-2:] if len(pcm_bytes) >= 2 else b'\x00\x00'
            padding = last_sample * ((EXPECTED_BYTES - len(pcm_bytes)) // 2)
            remainder = (EXPECTED_BYTES - len(pcm_bytes)) % 2
            pcm_bytes = pcm_bytes + padding + (b'\x00' * remainder)
        elif len(pcm_bytes) > EXPECTED_BYTES:
            log.warning("[VAD] get_speech_prob: chunk too long (%d bytes), truncating to %d",
                        len(pcm_bytes), EXPECTED_BYTES)
            pcm_bytes = pcm_bytes[:EXPECTED_BYTES]
        try:
            samples_np = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0
            if torch is not None:
                samples = torch.from_numpy(samples_np)
            else:
                samples = samples_np
            prob = self.model(samples, self.cfg.audio.input_sample_rate)
            return prob.item() if hasattr(prob, 'item') else float(prob)
        except Exception as e:
            log.error("[VAD] get_speech_prob error: %s", e)
            return 0.0

    @property
    def buffer_length(self) -> int:
        return len(self._audio_buffer)

    def get_buffer(self) -> bytes:
        """Get accumulated speech audio and reset buffer."""
        data = bytes(self._audio_buffer)
        self._audio_buffer = bytearray()
        return data

    def add_chunk(self, pcm_bytes: bytes):
        """Add audio to buffer regardless of VAD state (for manual accumulation).

        Guards against unbounded growth — drops oldest audio if buffer would
        exceed ~30 s at 16 kHz/16-bit mono (~960 KB).
        """
        MAX_BYTES = 960_000  # ~30 seconds
        self._audio_buffer.extend(pcm_bytes)
        if len(self._audio_buffer) > MAX_BYTES:
            # Keep the most recent audio, drop oldest
            excess = len(self._audio_buffer) - MAX_BYTES
            del self._audio_buffer[:excess]
            log.warning("VAD buffer overflow, dropped %d bytes of oldest audio", excess)


def wav_header(data_length: int, sample_rate: int, channels: int = 1, bits: int = 16) -> bytes:
    """Generate a WAV header for raw PCM data."""
    byte_rate = sample_rate * channels * bits // 8
    block_align = channels * bits // 8
    header = struct.pack(
        '<4sI4s4sIHHIIHH4sI',
        b'RIFF',
        data_length + 36,
        b'WAVE',
        b'fmt ',
        16,  # chunk size
        1,   # PCM format
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits,
        b'data',
        data_length
    )
    return header


def pcm_to_wav(pcm_data: bytes, sample_rate: int, channels: int = 1, bits: int = 16) -> bytes:
    """Wrap raw PCM data in a WAV header."""
    return wav_header(len(pcm_data), sample_rate, channels, bits) + pcm_data


class SmartTurnDetector:
    """End-of-turn classifier using pipecat Smart Turn v3 (audio-based ONNX).

    Takes raw 16kHz 16-bit mono PCM bytes and returns probability 0.0–1.0
    that the user's conversational turn is complete.

    Uses Whisper audio features as input — no transcript or conversation
    history required.  Works correctly on the very first turn.

    Falls back to 1.0 (always complete) if the model is unavailable,
    degrading gracefully to silence-only detection.
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

    def load(self):
        try:
            import os
            import urllib.request
            import onnxruntime as ort
            from transformers import WhisperFeatureExtractor

            model_dir = os.path.join(os.path.expanduser("~"), ".cache", "smartturn")
            model_path = os.path.join(model_dir, "smart_turn_v3.2_cpu.onnx")

            if not os.path.exists(model_path):
                log.info("[SmartTurn] Downloading Smart Turn v3.2 model (~30 MB)...")
                os.makedirs(model_dir, exist_ok=True)
                # Use httpx with timeout instead of urlretrieve (which has no timeout)
                import httpx
                try:
                    with httpx.Client(timeout=60.0) as http_client:
                        response = http_client.get(self._MODEL_URL)
                        response.raise_for_status()
                        with open(model_path, "wb") as f:
                            f.write(response.content)
                except Exception as download_err:
                    log.error("[SmartTurn] Model download failed: %s", download_err)
                    raise

            self._session = ort.InferenceSession(
                model_path, providers=["CPUExecutionProvider"]
            )
            self._extractor = WhisperFeatureExtractor.from_pretrained(
                "openai/whisper-tiny"
            )
            self._available = True
            log.info("Audio model loaded (pipecat smart-turn-v3.2)")
        except Exception as e:
            log.warning(
                "Could not load model (%s); "
                "falling back to silence-only detection", e
            )

    def _predict_sync(self, audio_bytes: bytes) -> float:
        """Run inference synchronously (called via run_in_executor)."""
        try:
            samples = (
                np.frombuffer(audio_bytes, dtype=np.int16).astype(np.float32)
                / 32768.0
            )
            samples = samples[-self._MAX_SAMPLES :]
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
            log.warning("Inference error: %s", e)
            return 1.0

    async def predict(self, audio_bytes: bytes) -> float:
        """Async wrapper — runs inference in a thread pool to avoid blocking.

        Args:
            audio_bytes: Raw 16kHz 16-bit mono PCM of the complete utterance.
        """
        if not self._available or not audio_bytes:
            return 1.0
        return await asyncio.get_running_loop().run_in_executor(
            None, self._predict_sync, audio_bytes
        )