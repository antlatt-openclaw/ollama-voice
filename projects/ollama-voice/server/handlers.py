"""Text-message handlers and dispatcher.

Each handler receives a typed message; the dispatcher parses incoming JSON
into the discriminated-union and routes by class. Pure protocol logic — no
FastAPI, no transport details.
"""

import logging
from typing import Awaitable, Callable

from config import Config
from models import (
    ConfigMessage, ConfigResetMessage, ConfigSavedMessage,
    EndRecordingMessage, GetConfigMessage, IncomingTextMessage,
    InterruptAckMessage, InterruptMessage, PingMessage, SetConfigMessage,
    TextQueryMessage, TranscriptMessage, TtsRequestMessage,
    ValidationError, parse_text_message,
)
from pipeline import generate_response, handle_tts_only, process_speech
from prompts import PromptStore
from session import Session

log = logging.getLogger("server")


TextHandler = Callable[[Session, IncomingTextMessage, Config, PromptStore], Awaitable[None]]


async def _on_interrupt(session: Session, msg: InterruptMessage, cfg: Config, prompts: PromptStore):
    if await session.try_interrupt():
        await session.send(InterruptAckMessage(request_id=msg.request_id))
        log.info("[%s] interrupt acknowledged", session.conn_id)


async def _on_end_recording(session: Session, msg: EndRecordingMessage, cfg: Config, prompts: PromptStore):
    if msg.history:
        session.warn_client_history_once()
    audio_data = session.audio_buffer.take()
    log.debug("[%s] end_recording: %d audio bytes", session.conn_id, len(audio_data))
    if audio_data and session.is_idle:
        log.info("[%s] processing %d bytes", session.conn_id, len(audio_data))
        session.spawn(process_speech(
            session, cfg, audio_data,
            effective_system_prompt=prompts.resolve(session.system_prompt),
        ))


async def _on_tts_request(session: Session, msg: TtsRequestMessage, cfg: Config, prompts: PromptStore):
    text = msg.text.strip()
    if text:
        session.spawn(handle_tts_only(session, cfg, text))


async def _on_text_query(session: Session, msg: TextQueryMessage, cfg: Config, prompts: PromptStore):
    if msg.history:
        session.warn_client_history_once()
    text = msg.text.strip()
    if not (text and session.is_idle):
        return
    log.info("[%s] text_query: %.60s", session.conn_id, text)
    await session.send(TranscriptMessage(text=text))
    session.spawn(_run_text_query(session, cfg, text, prompts))


async def _run_text_query(session: Session, cfg: Config, text: str, prompts: PromptStore):
    full = await generate_response(
        session, cfg, text,
        effective_system_prompt=prompts.resolve(session.system_prompt),
    )
    if full:
        session.append_turn(text, full)


async def _on_ping(session: Session, msg: PingMessage, cfg: Config, prompts: PromptStore):
    await session.send({"type": "pong"})


async def _on_get_config(session: Session, msg: GetConfigMessage, cfg: Config, prompts: PromptStore):
    await session.send(ConfigMessage(
        system_prompt=prompts.effective,
        is_default=prompts.is_default,
    ))


async def _on_set_config(session: Session, msg: SetConfigMessage, cfg: Config, prompts: PromptStore):
    if msg.system_prompt is not None:
        prompts.set(msg.system_prompt)
        session.system_prompt = msg.system_prompt
        await session.send(ConfigSavedMessage(system_prompt=msg.system_prompt))
        log.info("[%s] system prompt updated (%d chars)", session.conn_id, len(msg.system_prompt))
    else:
        prompts.reset()
        session.system_prompt = None
        await session.send(ConfigResetMessage(system_prompt=prompts.default))
        log.info("[%s] system prompt reset to default", session.conn_id)


_HANDLERS: dict[type, TextHandler] = {
    InterruptMessage: _on_interrupt,
    EndRecordingMessage: _on_end_recording,
    TtsRequestMessage: _on_tts_request,
    TextQueryMessage: _on_text_query,
    PingMessage: _on_ping,
    GetConfigMessage: _on_get_config,
    SetConfigMessage: _on_set_config,
}


async def dispatch_text(session: Session, data: dict, cfg: Config, prompts: PromptStore):
    """Parse and route an incoming text-frame dict to the appropriate handler."""
    try:
        msg = parse_text_message(data)
    except ValidationError as e:
        log.debug("[%s] invalid message: %s", session.conn_id, e)
        return
    handler = _HANDLERS.get(type(msg))
    if handler is None:
        log.debug("[%s] no handler for %s", session.conn_id, type(msg).__name__)
        return
    await handler(session, msg, cfg, prompts)
