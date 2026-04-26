"""Hands-free turn detection loop. Continuous VAD + SmartTurn end-of-turn classifier."""

import asyncio
import logging
import time

from audio import VAD, VAD_SPLIT_SIZE, SmartTurnDetector
from config import Config
from models import (
    ListeningEndMessage, ListeningStartMessage, TranscriptMessage,
)
from pipeline import generate_response
from session import ServerState, Session
from stt import transcribe

log = logging.getLogger("server")


async def hands_free_processor(
    session: Session,
    cfg: Config,
    vad: VAD,
    smart_turn: SmartTurnDetector,
    effective_system_prompt: str,
):
    """Drain session.hf_audio_q, detect turns, run STT → LLM → TTS per turn."""
    assert session.hf_audio_q is not None

    speech_threshold = cfg.vad.speech_threshold
    silence_ms = cfg.hands_free.silence_ms
    max_listen_secs = cfg.hands_free.max_listen_secs
    min_audio_bytes = cfg.hands_free.min_audio_bytes
    smart_turn_threshold = cfg.hands_free.smart_turn_threshold
    chunk_ms = (cfg.vad.window_size_samples / cfg.audio.input_sample_rate) * 1000
    silence_chunks_needed = int(silence_ms / chunk_ms)

    speech_buf = bytearray()
    silence_chunks = 0
    is_collecting = False
    listen_start = 0.0

    log.info("[%s] HF processor loop starting (threshold=%.2f)", session.conn_id, speech_threshold)
    prob_log_counter = 0

    async def _send(msg):
        try:
            await session.ws.send_json(msg.model_dump())
        except Exception as e:
            log.warning("[%s] HF send error: %s", session.conn_id, e)

    while True:
        try:
            try:
                chunk = await asyncio.wait_for(session.hf_audio_q.get(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            if chunk is None:
                break

            if session.state in (ServerState.PROCESSING, ServerState.RESPONDING):
                # Drain queue while busy (these are likely echo of our own TTS)
                while True:
                    try:
                        session.hf_audio_q.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                if is_collecting:
                    is_collecting = False
                    speech_buf = bytearray()
                    silence_chunks = 0
                continue

            prob = vad.get_speech_prob(chunk)
            prob_log_counter += 1
            if prob_log_counter % 30 == 1:
                log.debug("[%s] HF VAD prob=%.3f state=%s collecting=%s",
                          session.conn_id, prob, session.state.name, is_collecting)

            if prob >= speech_threshold:
                if not is_collecting:
                    is_collecting = True
                    listen_start = time.monotonic()
                    silence_chunks = 0
                    await _send(ListeningStartMessage())
                    log.debug("[%s] HF speech onset", session.conn_id)
                else:
                    silence_chunks = 0
                speech_buf.extend(chunk)
                continue

            if not is_collecting:
                continue

            speech_buf.extend(chunk)
            silence_chunks += 1
            elapsed = time.monotonic() - listen_start

            if silence_chunks < silence_chunks_needed and elapsed < max_listen_secs:
                continue

            audio_data = bytes(speech_buf)

            if len(audio_data) < min_audio_bytes:
                log.debug("[%s] HF audio too short, discarding", session.conn_id)
                is_collecting = False
                speech_buf = bytearray()
                silence_chunks = 0
                await _send(ListeningEndMessage())
                continue

            turn_prob = 1.0
            if elapsed < max_listen_secs:
                turn_prob = await smart_turn.predict(audio_data)
                if turn_prob < smart_turn_threshold:
                    log.debug("[%s] HF SmartTurn not complete (%.3f), continuing",
                              session.conn_id, turn_prob)
                    # Trim the silence chunks we just appended so they don't
                    # inflate the buffer on the next iteration.
                    trim_bytes = silence_chunks * VAD_SPLIT_SIZE
                    if trim_bytes <= len(speech_buf):
                        del speech_buf[-trim_bytes:]
                    silence_chunks = 0
                    continue

            log.info("[%s] HF turn complete (prob=%.3f), STT on %d bytes",
                     session.conn_id, turn_prob, len(audio_data))

            if not session.is_idle:
                log.debug("[%s] HF state not idle (%s), discarding turn",
                          session.conn_id, session.state.name)
                is_collecting = False
                speech_buf = bytearray()
                silence_chunks = 0
                await _send(ListeningEndMessage())
                continue

            transcript = await transcribe(
                audio_data, cfg.stt, input_sample_rate=cfg.audio.input_sample_rate
            )

            is_collecting = False
            speech_buf = bytearray()
            silence_chunks = 0

            if not transcript or not transcript.strip():
                log.debug("[%s] HF empty transcript, discarding", session.conn_id)
                await _send(ListeningEndMessage())
                continue

            log.info("[%s] HF transcript: '%.60s'", session.conn_id, transcript)
            await _send(ListeningEndMessage())
            await _send(TranscriptMessage(text=transcript))

            if not session.is_idle:
                log.debug("[%s] HF state changed during STT (%s), skipping generate",
                          session.conn_id, session.state.name)
                continue

            full_response = await generate_response(
                session, cfg, transcript, effective_system_prompt
            )
            if full_response:
                session.append_turn(transcript, full_response)

            # Drain queue to discard echoed TTS audio captured by the mic.
            drained = 0
            while True:
                try:
                    session.hf_audio_q.get_nowait()
                    drained += 1
                except asyncio.QueueEmpty:
                    break
            if drained:
                log.debug("[%s] HF drained %d echo chunks", session.conn_id, drained)

        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.exception("[%s] HF processor exception: %s", session.conn_id, e)
            if is_collecting:
                try:
                    await _send(ListeningEndMessage())
                except Exception:
                    pass
            is_collecting = False
            speech_buf = bytearray()
            silence_chunks = 0

    log.info("[%s] HF processor exited", session.conn_id)
