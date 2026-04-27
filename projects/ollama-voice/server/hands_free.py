"""Hands-free turn detection loop. Continuous VAD + SmartTurn end-of-turn classifier."""

import asyncio
import logging
import time
from enum import Enum

from smart_turn import SmartTurnDetector
from vad import VAD, VAD_SPLIT_SIZE
from config import Config
from models import (
    ListeningEndMessage, ListeningStartMessage, TranscriptMessage,
)
from pipeline import generate_response
from session import ServerState, Session
from stt import transcribe

log = logging.getLogger("server")


class TurnEvent(Enum):
    NONE = "none"          # nothing of note this chunk
    ONSET = "onset"        # speech just started — notify client
    COMPLETE = "complete"  # turn captured, ready for STT
    TOO_SHORT = "too_short"  # turn ended but below min_audio_bytes — discard


class TurnCollector:
    """VAD + silence + SmartTurn state machine for one hands-free conversation.

    feed() takes one VAD-window chunk and returns (event, audio?). The caller
    drives I/O (sending ListeningStart/End, running STT/LLM); the collector
    just decides when a turn has begun and ended.
    """

    def __init__(self, cfg: Config, vad: VAD, smart_turn: SmartTurnDetector):
        self._cfg = cfg
        self._vad = vad
        self._smart_turn = smart_turn
        chunk_ms = (cfg.vad.window_size_samples / cfg.audio.input_sample_rate) * 1000
        self._silence_chunks_needed = int(cfg.hands_free.silence_ms / chunk_ms)
        self.reset()

    def reset(self):
        self._buf = bytearray()
        self._silence_chunks = 0
        self._collecting = False
        self._listen_start = 0.0

    @property
    def is_collecting(self) -> bool:
        return self._collecting

    async def feed(self, chunk: bytes) -> tuple[TurnEvent, bytes | None]:
        prob = self._vad.get_speech_prob(chunk)
        speech_threshold = self._cfg.vad.speech_threshold
        max_listen_secs = self._cfg.hands_free.max_listen_secs

        if prob >= speech_threshold:
            self._buf.extend(chunk)
            if not self._collecting:
                self._collecting = True
                self._listen_start = time.monotonic()
                self._silence_chunks = 0
                return (TurnEvent.ONSET, None)
            self._silence_chunks = 0
            return (TurnEvent.NONE, None)

        if not self._collecting:
            return (TurnEvent.NONE, None)

        self._buf.extend(chunk)
        self._silence_chunks += 1
        elapsed = time.monotonic() - self._listen_start

        if self._silence_chunks < self._silence_chunks_needed and elapsed < max_listen_secs:
            return (TurnEvent.NONE, None)

        audio = bytes(self._buf)
        if len(audio) < self._cfg.hands_free.min_audio_bytes:
            self.reset()
            return (TurnEvent.TOO_SHORT, None)

        # SmartTurn gate — skipped if we hit the hard max-listen cap.
        if elapsed < max_listen_secs:
            turn_prob = await self._smart_turn.predict(audio)
            if turn_prob < self._cfg.hands_free.smart_turn_threshold:
                # Trim trailing silence so it doesn't inflate the next pass.
                trim = self._silence_chunks * VAD_SPLIT_SIZE
                if trim <= len(self._buf):
                    del self._buf[-trim:]
                self._silence_chunks = 0
                return (TurnEvent.NONE, None)

        self.reset()
        return (TurnEvent.COMPLETE, audio)


def _drain_queue(q: asyncio.Queue) -> int:
    drained = 0
    while True:
        try:
            q.get_nowait()
            drained += 1
        except asyncio.QueueEmpty:
            break
    return drained


async def _abort_turn(session: Session, reason: str):
    """Discard the current HF turn and tell the client we stopped listening."""
    log.debug("[%s] HF abort: %s", session.conn_id, reason)
    await session.send(ListeningEndMessage())


async def hands_free_processor(
    session: Session,
    cfg: Config,
    vad: VAD,
    smart_turn: SmartTurnDetector,
    effective_system_prompt: str,
):
    """Drain session.hf_audio_q, detect turns, run STT → LLM → TTS per turn."""
    assert session.hf_audio_q is not None

    collector = TurnCollector(cfg, vad, smart_turn)
    log.info("[%s] HF processor loop starting (threshold=%.2f)",
             session.conn_id, cfg.vad.speech_threshold)

    try:
        while True:
            try:
                chunk = await session.hf_audio_q.get()

                if session.state in (ServerState.PROCESSING, ServerState.RESPONDING):
                    # Drain queue while busy (these are likely echo of our own TTS).
                    _drain_queue(session.hf_audio_q)
                    if collector.is_collecting:
                        collector.reset()
                    continue

                event, audio = await collector.feed(chunk)

                if event == TurnEvent.ONSET:
                    await session.send(ListeningStartMessage())
                    log.debug("[%s] HF speech onset", session.conn_id)
                    continue

                if event == TurnEvent.TOO_SHORT:
                    await _abort_turn(session, "audio too short")
                    continue

                if event != TurnEvent.COMPLETE:
                    continue

                assert audio is not None
                log.info("[%s] HF turn complete, STT on %d bytes", session.conn_id, len(audio))

                if not session.is_idle:
                    await _abort_turn(session, f"state not idle ({session.state.name})")
                    continue

                transcript = await transcribe(
                    audio, cfg.stt, input_sample_rate=cfg.audio.input_sample_rate
                )

                if not transcript or not transcript.strip():
                    await _abort_turn(session, "empty transcript")
                    continue

                log.info("[%s] HF transcript: '%.60s'", session.conn_id, transcript)
                await session.send(ListeningEndMessage())
                await session.send(TranscriptMessage(text=transcript))

                if not session.is_idle:
                    log.debug("[%s] HF state changed during STT (%s), skipping generate",
                              session.conn_id, session.state.name)
                    continue

                full_response = await generate_response(
                    session, cfg, transcript, effective_system_prompt
                )
                if full_response:
                    session.append_turn(transcript, full_response)

                drained = _drain_queue(session.hf_audio_q)
                if drained:
                    log.debug("[%s] HF drained %d echo chunks", session.conn_id, drained)

            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.exception("[%s] HF processor exception: %s", session.conn_id, e)
                if collector.is_collecting:
                    try:
                        await session.send(ListeningEndMessage())
                    except Exception:
                        pass
                collector.reset()
    finally:
        log.info("[%s] HF processor exited", session.conn_id)
