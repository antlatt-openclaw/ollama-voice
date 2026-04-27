"""End-of-turn classifier — pipecat smart-turn-v3.2 (ONNX).

Lazy-loads the model on first use. Falls back to "always complete" (1.0)
if the model can't be loaded — the rest of the pipeline still works using
silence-only turn detection.
"""

import asyncio
import logging

import numpy as np

log = logging.getLogger("server")


class SmartTurnDetector:
    """End-of-turn classifier (pipecat smart-turn-v3.2 ONNX). Lazy-loaded."""

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
