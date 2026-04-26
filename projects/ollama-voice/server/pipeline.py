"""STT → LLM → TTS pipeline. Per-turn orchestration.

Architecturally we synthesize the full LLM response in a single TTS call.
Token deltas stream to the client as text for live display, but audio is
sent only after the LLM completes. Trade-off: higher first-audio latency
in exchange for natural prosody across the whole utterance.
"""

import logging

from config import Config
from models import (
    AudioEndMessage, AudioStartMessage, ErrorMessage,
    ResponseDeltaMessage, ResponseEndMessage, ResponseStartMessage,
    TranscriptMessage, TtsOnlyEndMessage, TtsOnlyStartMessage,
)
from ollama import stream_ollama_tokens
from session import ServerState, Session
from stt import transcribe
from tts import synthesize

log = logging.getLogger("server")

# WebSocket binary chunk size for outgoing audio.
AUDIO_CHUNK_SIZE = 4096


async def _send_json(session: Session, msg):
    if session.is_interrupted:
        return
    try:
        data = msg.model_dump() if hasattr(msg, "model_dump") else msg
        await session.ws.send_json(data)
    except Exception as e:
        log.warning("[%s] send_json error: %s", session.conn_id, e)


async def _send_audio(session: Session, pcm: bytes) -> bool:
    for i in range(0, len(pcm), AUDIO_CHUNK_SIZE):
        if session.is_interrupted:
            return False
        try:
            await session.ws.send_bytes(pcm[i:i + AUDIO_CHUNK_SIZE])
        except Exception as e:
            log.warning("[%s] send_audio error: %s", session.conn_id, e)
            return False
    return True


async def generate_response(
    session: Session,
    cfg: Config,
    text: str,
    effective_system_prompt: str,
) -> str | None:
    """Stream LLM tokens to client, synthesize the full reply, then stream audio."""
    log.info("[%s] generate_response text='%.60s' history=%d",
             session.conn_id, text, len(session.history))
    await session.to_state(ServerState.RESPONDING)

    await _send_json(session, ResponseStartMessage(text=""))

    full_response = ""
    try:
        async for delta, accumulated in stream_ollama_tokens(
            text, cfg.ollama,
            system_prompt=effective_system_prompt,
            history=session.history_snapshot(),
        ):
            if session.is_interrupted:
                break
            full_response = accumulated
            await _send_json(session, ResponseDeltaMessage(text=delta))
    except Exception as e:
        log.error("[%s] LLM streaming error: %s", session.conn_id, e)

    if session.is_interrupted:
        log.debug("[%s] interrupted during LLM", session.conn_id)
        await session.to_state(ServerState.IDLE)
        return None

    if not full_response.strip():
        await _send_json(session, ErrorMessage(message="No response from Ollama"))
        await session.to_state(ServerState.IDLE)
        return None

    log.info("[%s] synthesizing full response (%d chars)", session.conn_id, len(full_response.strip()))
    audio = await synthesize(full_response.strip(), cfg.tts)

    if session.is_interrupted:
        log.debug("[%s] interrupted during TTS, dropping audio", session.conn_id)
        await session.to_state(ServerState.IDLE)
        return None

    if audio:
        duration_ms = int(len(audio) / (cfg.tts.output_sample_rate * 2) * 1000)
        await _send_json(session, AudioStartMessage(duration_ms=duration_ms))
        if await _send_audio(session, audio):
            await _send_json(session, AudioEndMessage())

    if session.is_interrupted:
        await session.to_state(ServerState.IDLE)
        return None

    await _send_json(session, ResponseEndMessage(text=full_response))
    log.info("[%s] response complete: %.80s", session.conn_id, full_response)
    await session.to_state(ServerState.IDLE)
    return full_response


async def process_speech(
    session: Session,
    cfg: Config,
    audio_data: bytes,
    effective_system_prompt: str,
):
    """Full PTT turn: STT → LLM → TTS."""
    await session.to_state(ServerState.PROCESSING)

    log.info("[%s] transcribing %d bytes of audio", session.conn_id, len(audio_data))
    try:
        text = await transcribe(audio_data, cfg.stt, input_sample_rate=cfg.audio.input_sample_rate)
    except Exception as e:
        log.error("[%s] STT error: %s", session.conn_id, e)
        await _send_json(session, ErrorMessage(message="Transcription failed"))
        await session.to_state(ServerState.IDLE)
        return

    if not text:
        await _send_json(session, ErrorMessage(message="Could not transcribe audio"))
        await session.to_state(ServerState.IDLE)
        return

    await _send_json(session, TranscriptMessage(text=text))
    log.info("[%s] transcribed: %s", session.conn_id, text)

    if session.is_interrupted:
        await session.to_state(ServerState.IDLE)
        return

    full_response = await generate_response(session, cfg, text, effective_system_prompt)
    if full_response:
        session.append_turn(text, full_response)


async def handle_tts_only(session: Session, cfg: Config, text: str):
    """Synthesize and stream audio without touching conversation state."""
    if not session.is_idle:
        log.info("[%s] TTS-only ignored — busy (%s)", session.conn_id, session.state.value)
        return

    await session.to_state(ServerState.RESPONDING)
    log.info("[%s] TTS-only: %.60s", session.conn_id, text)
    try:
        await _send_json(session, TtsOnlyStartMessage())
        audio = await synthesize(text, cfg.tts)
        if audio is not None and not session.is_interrupted:
            duration_ms = int(len(audio) / (cfg.tts.output_sample_rate * 2) * 1000)
            await _send_json(session, AudioStartMessage(duration_ms=duration_ms))
            if await _send_audio(session, audio):
                await _send_json(session, AudioEndMessage())
    finally:
        await session.to_state(ServerState.IDLE)
        await _send_json(session, TtsOnlyEndMessage())
