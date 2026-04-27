"""WebSocket connection lifecycle.

Owns one connection from accept → auth → register → receive loop → cleanup.
The FastAPI route handler in ``app.py`` is a thin wrapper that calls
``run_session()``.
"""

import asyncio
import json
import logging
import secrets
import uuid
from dataclasses import dataclass

from fastapi import WebSocket, WebSocketDisconnect

from config import Config
from handlers import dispatch_text
from hands_free import hands_free_processor
from models import (
    AuthFailedMessage, AuthOkMessage, ConnectionReplacedMessage, parse_auth_message,
)
from prompts import PromptStore
from registry import SessionRegistry
from session import HF_QUEUE_MAX, ServerState, Session
from smart_turn import SmartTurnDetector
from vad import VAD, VAD_SPLIT_SIZE, pad_to_vad_window

log = logging.getLogger("server")

# Maximum size (bytes) for a single JSON text message from the client.
MAX_JSON_MSG_SIZE = 65536


@dataclass
class ConnectionDeps:
    """Dependencies a connection needs from app-state. Built once in lifespan."""
    cfg: Config
    sessions: SessionRegistry
    prompts: PromptStore
    vad: VAD
    smart_turn: SmartTurnDetector
    shutdown_event: asyncio.Event


async def run_session(ws: WebSocket, deps: ConnectionDeps):
    """Full per-connection lifecycle. Cleanup is guaranteed via the finally block."""
    await ws.accept(subprotocol="openclaw-voice")
    log.info("WebSocket connected, waiting for auth")

    session = await _authenticate(ws, deps.cfg)
    if session is None:
        return

    try:
        await _register_session(deps.sessions, session)
        if session.mode == "hands_free" and not await _start_hands_free(session, deps):
            return
        await _receive_loop(session, deps)
    except WebSocketDisconnect:
        log.info("[%s] client disconnected", session.conn_id)
    except Exception as e:
        log.error("[%s] websocket error: %s", session.conn_id, e)
    finally:
        session.state = ServerState.INTERRUPTED
        await session.cancel_all()
        await deps.sessions.remove(session)
        session.state = ServerState.IDLE
        log.info("[%s] connection closed", session.conn_id)


# ── Lifecycle helpers ─────────────────────────────────────────────────────


async def _authenticate(ws: WebSocket, cfg: Config) -> Session | None:
    """Run the auth handshake. Returns the new Session, or None on failure
    (in which case the WebSocket has already been closed with the right code)."""
    try:
        auth_msg = await asyncio.wait_for(ws.receive(), timeout=cfg.server.auth_timeout)
    except asyncio.TimeoutError:
        await ws.close(code=4001, reason="Auth timeout")
        return None

    if not (auth_msg.get("type") == "websocket.receive" and "text" in auth_msg):
        log.warning("Unexpected auth message format")
        await ws.close(code=4002, reason="Expected auth message")
        return None

    try:
        auth = parse_auth_message(json.loads(auth_msg["text"]))
    except Exception as e:
        log.warning("Auth parse error: %s", e)
        await ws.close(code=4002, reason="Invalid auth message")
        return None

    if not secrets.compare_digest(auth.token, cfg.server.auth_token):
        try:
            await ws.send_json(AuthFailedMessage(reason="Invalid token").model_dump())
        except Exception:
            pass
        await asyncio.sleep(0.05)
        await ws.close(code=4003, reason="Invalid token")
        return None

    conn_id = auth.connection_id or str(uuid.uuid4())
    log.info("[%s] mode=%s system_prompt_override=%s",
             conn_id, auth.mode, "yes" if auth.system_prompt else "no")
    return Session(
        ws=ws, conn_id=conn_id, mode=auth.mode, system_prompt=auth.system_prompt,
    )


async def _register_session(sessions: SessionRegistry, session: Session):
    """Install the new session as the active one; kick any predecessor.

    The old session's pipeline tasks are cancelled and awaited *before* the
    new session is told it's authenticated, so the new client never observes
    both sessions running concurrently.
    """
    old = await sessions.replace(session)
    if old is not None and old.ws is not session.ws:
        old.state = ServerState.INTERRUPTED  # short-circuit any in-flight sends
        await old.cancel_all()
        try:
            await old.send(ConnectionReplacedMessage())
            await old.ws.close()
        except Exception:
            pass
    await session.send(AuthOkMessage())
    log.info("[%s] authenticated", session.conn_id)


async def _start_hands_free(session: Session, deps: ConnectionDeps) -> bool:
    """Lazy-load HF models and spawn the processor. Returns False if model load failed."""
    try:
        await deps.vad.ensure_loaded()
        await deps.smart_turn.ensure_loaded()
    except Exception as e:
        log.error("[%s] HF model load failed: %s", session.conn_id, e)
        await session.ws.close(code=1011, reason="HF init failed")
        return False

    session.hf_audio_q = asyncio.Queue(maxsize=HF_QUEUE_MAX)
    session.spawn(hands_free_processor(
        session, deps.cfg, deps.vad, deps.smart_turn,
        effective_system_prompt=deps.prompts.resolve(session.system_prompt),
    ))
    log.info("[%s] HF processor started", session.conn_id)
    return True


async def _receive_loop(session: Session, deps: ConnectionDeps):
    """Read frames until disconnect or shutdown; route text → dispatch, bytes → audio."""
    while not deps.shutdown_event.is_set():
        msg = await session.ws.receive()

        if msg.get("type") == "websocket.disconnect":
            break

        if msg.get("type") == "websocket.receive" and "text" in msg:
            if len(msg["text"]) > MAX_JSON_MSG_SIZE:
                log.warning("[%s] oversized JSON (%d bytes), dropping",
                            session.conn_id, len(msg["text"]))
                continue
            try:
                data = json.loads(msg["text"])
            except json.JSONDecodeError:
                continue
            await dispatch_text(session, data, deps.cfg, deps.prompts)
            continue

        if msg.get("type") == "websocket.receive" and "bytes" in msg:
            try:
                _ingest_audio(session, msg["bytes"])
            except Exception as e:
                log.exception("[%s] audio chunk error: %s", session.conn_id, e)


def _ingest_audio(session: Session, audio_chunk: bytes):
    """PTT: append to buffer. HF: split + pad + enqueue."""
    if session.mode == "hands_free":
        assert session.hf_audio_q is not None
        for i in range(0, len(audio_chunk), VAD_SPLIT_SIZE):
            chunk = pad_to_vad_window(audio_chunk[i:i + VAD_SPLIT_SIZE])
            _enqueue_hf_chunk(session, chunk)
    else:
        session.audio_buffer.add(audio_chunk)


def _enqueue_hf_chunk(session: Session, chunk: bytes):
    """put_nowait into hf_audio_q; on QueueFull, drop the oldest chunk first."""
    assert session.hf_audio_q is not None
    try:
        session.hf_audio_q.put_nowait(chunk)
        return
    except asyncio.QueueFull:
        pass
    try:
        session.hf_audio_q.get_nowait()
    except asyncio.QueueEmpty:
        pass
    try:
        session.hf_audio_q.put_nowait(chunk)
    except asyncio.QueueFull:
        return
    session.warn_hf_queue_drop_once()
