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
from session import AUDIO_CHUNK_SIZE, ServerState, Session  # noqa: F401  AUDIO_CHUNK_SIZE re-exported for tests
from stt import transcribe
from tts import synthesize

log = logging.getLogger("server")


async def generate_response(
    session: Session,
    cfg: Config,
    text: str,
    effective_system_prompt: str,
) -> str | None:
    """Stream LLM tokens to client, synthesize the full reply, then stream audio."""
    log.info("[%s] generate_response text='%.60s' history=%d",
             session.conn_id, text, len(session.history))

    async with session.in_state(ServerState.RESPONDING):
        await session.send_if_active(ResponseStartMessage(text=""))

        full_response = ""
        error_detail: str | None = None
        try:
            async for delta, accumulated in stream_ollama_tokens(
                text, cfg.ollama,
                system_prompt=effective_system_prompt,
                history=session.history_snapshot(),
            ):
                if session.is_interrupted:
                    break
                full_response = accumulated
                await session.send_if_active(ResponseDeltaMessage(text=delta))
        except Exception as e:
            error_detail = str(e) or e.__class__.__name__
            log.error("[%s] LLM streaming error: %s", session.conn_id, error_detail)

        if session.is_interrupted:
            log.debug("[%s] interrupted during LLM", session.conn_id)
            return None

        if not full_response.strip():
            await session.send_if_active(ErrorMessage(message=error_detail or "No response from Ollama"))
            return None

        log.info("[%s] synthesizing full response (%d chars)", session.conn_id, len(full_response.strip()))
        audio = await synthesize(full_response.strip(), cfg.tts)

        if session.is_interrupted:
            log.debug("[%s] interrupted during TTS, dropping audio", session.conn_id)
            return None

        if audio:
            duration_ms = int(len(audio) / (cfg.tts.output_sample_rate * 2) * 1000)
            await session.send_if_active(AudioStartMessage(duration_ms=duration_ms))
            if await session.send_audio(audio):
                await session.send_if_active(AudioEndMessage())

        if session.is_interrupted:
            return None

        await session.send_if_active(ResponseEndMessage(text=full_response))
        log.info("[%s] response complete: %.80s", session.conn_id, full_response)
        return full_response


async def process_speech(
    session: Session,
    cfg: Config,
    audio_data: bytes,
    effective_system_prompt: str,
):
    """Full PTT turn: STT → LLM → TTS."""
    text = await _do_stt(session, cfg, audio_data)
    if text is None:
        return
    full_response = await generate_response(session, cfg, text, effective_system_prompt)
    if full_response:
        session.append_turn(text, full_response)


async def _do_stt(session: Session, cfg: Config, audio_data: bytes) -> str | None:
    """STT phase of process_speech. Returns transcript or None if no usable result.

    Owns the PROCESSING state and sends the user-facing TranscriptMessage on success.
    """
    async with session.in_state(ServerState.PROCESSING):
        log.info("[%s] transcribing %d bytes of audio", session.conn_id, len(audio_data))
        try:
            text = await transcribe(audio_data, cfg.stt, input_sample_rate=cfg.audio.input_sample_rate)
        except Exception as e:
            log.error("[%s] STT error: %s", session.conn_id, e)
            await session.send_if_active(ErrorMessage(message="Transcription failed"))
            return None

        if not text:
            await session.send_if_active(ErrorMessage(message="Could not transcribe audio"))
            return None

        await session.send_if_active(TranscriptMessage(text=text))
        log.info("[%s] transcribed: %s", session.conn_id, text)

        if session.is_interrupted:
            return None

        return text


async def handle_tts_only(session: Session, cfg: Config, text: str):
    """Synthesize and stream audio without touching conversation state."""
    if not session.is_idle:
        log.info("[%s] TTS-only ignored — busy (%s)", session.conn_id, session.state.value)
        return

    log.info("[%s] TTS-only: %.60s", session.conn_id, text)
    async with session.in_state(ServerState.RESPONDING):
        try:
            await session.send_if_active(TtsOnlyStartMessage())
            audio = await synthesize(text, cfg.tts)
            if audio is not None and not session.is_interrupted:
                duration_ms = int(len(audio) / (cfg.tts.output_sample_rate * 2) * 1000)
                await session.send_if_active(AudioStartMessage(duration_ms=duration_ms))
                if await session.send_audio(audio):
                    await session.send_if_active(AudioEndMessage())
        finally:
            await session.send_if_active(TtsOnlyEndMessage())
