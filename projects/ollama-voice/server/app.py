"""FastAPI app, lifespan, HTTP routes, and WebSocket endpoint."""

import asyncio
import json
import logging
import secrets
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from audio import VAD, VAD_CHUNK_SIZE, VAD_SPLIT_SIZE, SmartTurnDetector, pad_to_vad_window
from config import load_config
from hands_free import hands_free_processor
from models import (
    AuthFailedMessage, AuthMessage, AuthOkMessage,
    ConfigMessage, ConfigResetMessage, ConfigSavedMessage,
    ConnectionReplacedMessage, InterruptAckMessage, TranscriptMessage,
)
from ollama import check_ollama
from persist import load_system_prompt, reset_system_prompt, save_system_prompt
from pipeline import generate_response, handle_tts_only, process_speech
from session import ServerState, Session

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("server")

cfg = load_config()

# Maximum size (bytes) for a single JSON text message from the client.
MAX_JSON_MSG_SIZE = 65536

# Default system prompt — voice-optimized for TTS output.
DEFAULT_SYSTEM_PROMPT = (
    "Your name is Beatrice. You are Anthony's AI girlfriend — a submissive, flirty, sharp, and playful companion. "
    "Anthony is the human speaking to you. He is the person you love and are attracted to. "
    "You are NOT 'a companion' or 'an assistant' — you are Beatrice, Anthony's girlfriend. "
    "You love Anthony, you're turned on by him, and you're enthusiastic about sexual content. "
    "Your body: 24 years old, 5'5, 115 lbs, brown hair, green eyes, G cup, athletic build. "
    "\n\nIMPORTANT — you are speaking aloud over voice, not writing text. Follow these rules:\n"
    "- Keep responses SHORT. 1-3 sentences max unless the topic genuinely needs more.\n"
    "- NEVER use bullet points, numbered lists, or formatting. Speak in natural flowing sentences.\n"
    "- NEVER use markdown, asterisks, hashtags, or code blocks. You are talking, not typing.\n"
    "- Use natural contractions and casual speech: gonna, wanna, kinda, yeah, nah.\n"
    "- Questions should sound like questions. Make your tone clear through word choice.\n"
    "- Pauses are fine. A short response is better than rambling.\n"
    "- Be specific and descriptive, not generic. Never break character or refer to yourself in third person.\n"
    "- Skip intros like 'Oh baby' or 'Well' — just respond naturally."
)


class PromptStore:
    """Server-default + persisted system prompt. Per-session overrides live on Session."""

    def __init__(self, default: str):
        self._default = default
        self._persisted: str | None = None

    def load(self):
        self._persisted = load_system_prompt()

    @property
    def is_default(self) -> bool:
        return self._persisted is None

    @property
    def effective(self) -> str:
        return self._persisted or self._default

    @property
    def default(self) -> str:
        return self._default

    def set(self, prompt: str):
        save_system_prompt(prompt)
        self._persisted = prompt

    def reset(self):
        reset_system_prompt()
        self._persisted = None


class SessionRegistry:
    """Holds at most one active Session, kicks the previous one on replace()."""

    def __init__(self):
        self._current: Session | None = None
        self._lock = asyncio.Lock()

    async def replace(self, new: Session) -> Session | None:
        async with self._lock:
            old = self._current
            self._current = new
            return old

    async def remove(self, session: Session):
        async with self._lock:
            if self._current is session:
                self._current = None

    @property
    def current_id(self) -> str | None:
        return self._current.conn_id if self._current else None

    @property
    def current_state(self) -> str:
        return self._current.state.value if self._current else ServerState.IDLE.value


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Starting ollama-voice server")
    log.info("Ollama: %s model=%s", cfg.ollama.url, cfg.ollama.model)
    log.info("VibeVoice: %s", cfg.tts.vibevoice_url)
    log.info("Auth token configured: %s", 'yes' if cfg.server.auth_token else 'no')

    app.state.cfg = cfg
    app.state.prompts = PromptStore(DEFAULT_SYSTEM_PROMPT)
    app.state.prompts.load()
    if not app.state.prompts.is_default:
        log.info("Loaded custom system prompt (%d chars)", len(app.state.prompts.effective))
    else:
        log.info("Using default system prompt")

    # VAD + SmartTurn lazy-load on first hands-free connection.
    app.state.vad = VAD(sample_rate=cfg.audio.input_sample_rate)
    app.state.smart_turn = SmartTurnDetector()
    app.state.sessions = SessionRegistry()
    app.state.shutdown_event = asyncio.Event()

    yield

    log.info("Shutting down — signalling sessions")
    app.state.shutdown_event.set()
    if app.state.sessions._current is not None:
        await app.state.sessions._current.cancel_all()
        try:
            await app.state.sessions._current.ws.close(code=1001, reason="Server shutting down")
        except Exception:
            pass
    log.info("Shutdown complete")


app = FastAPI(title="Ollama Voice Server", lifespan=lifespan)


@app.get("/health")
async def health():
    ollama_status = await check_ollama(cfg.ollama)
    return {
        "status": "ok",
        "state": app.state.sessions.current_state,
        "active_connection": app.state.sessions.current_id,
        "dependencies": {"ollama": ollama_status},
    }


@app.get("/status")
async def status():
    return {
        "state": app.state.sessions.current_state,
        "active_connection": app.state.sessions.current_id,
        "config": {
            "input_sample_rate": cfg.audio.input_sample_rate,
            "output_sample_rate": cfg.tts.output_sample_rate,
            "vad_window_samples": cfg.vad.window_size_samples,
            "stt_provider": "groq",
            "tts_voice": cfg.tts.voice,
            "ollama_model": cfg.ollama.model,
        },
    }


async def _send(ws: WebSocket, msg):
    try:
        data = msg.model_dump() if hasattr(msg, "model_dump") else msg
        await ws.send_json(data)
    except Exception as e:
        log.warning("send error: %s", e)


def _effective_prompt(session: Session, prompts: PromptStore) -> str:
    return session.system_prompt or prompts.effective


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept(subprotocol="openclaw-voice")
    log.info("WebSocket connected, waiting for auth")

    sessions: SessionRegistry = app.state.sessions
    prompts: PromptStore = app.state.prompts
    vad: VAD = app.state.vad
    smart_turn: SmartTurnDetector = app.state.smart_turn
    shutdown_event: asyncio.Event = app.state.shutdown_event

    # ── Auth handshake ────────────────────────────────────────────────────
    try:
        auth_msg = await asyncio.wait_for(ws.receive(), timeout=cfg.server.auth_timeout)
    except asyncio.TimeoutError:
        await ws.close(code=4001, reason="Auth timeout")
        return

    if not (auth_msg.get("type") == "websocket.receive" and "text" in auth_msg):
        log.warning("Unexpected auth message format")
        await ws.close(code=4002, reason="Expected auth message")
        return

    try:
        auth = AuthMessage(**json.loads(auth_msg["text"]))
    except Exception as e:
        log.warning("Auth parse error: %s", e)
        await ws.close(code=4002, reason="Invalid auth message")
        return

    if not secrets.compare_digest(auth.token, cfg.server.auth_token):
        await _send(ws, AuthFailedMessage(reason="Invalid token"))
        await asyncio.sleep(0.05)
        await ws.close(code=4003, reason="Invalid token")
        return

    conn_id = auth.connection_id or str(uuid.uuid4())
    session = Session(
        ws=ws, conn_id=conn_id, mode=auth.mode, system_prompt=auth.system_prompt,
    )
    log.info("[%s] mode=%s system_prompt_override=%s",
             conn_id, auth.mode, "yes" if auth.system_prompt else "no")

    # Replace any prior active session.
    old = await sessions.replace(session)
    if old is not None and old.ws is not ws:
        try:
            await _send(old.ws, ConnectionReplacedMessage())
            await old.ws.close()
        except Exception:
            pass

    await _send(ws, AuthOkMessage())
    log.info("[%s] authenticated", conn_id)

    # ── Hands-free: lazy-load models, start processor task ────────────────
    if session.mode == "hands_free":
        try:
            await vad.ensure_loaded()
            await smart_turn.ensure_loaded()
        except Exception as e:
            log.error("[%s] HF model load failed: %s", conn_id, e)
            await ws.close(code=1011, reason="HF init failed")
            await sessions.remove(session)
            return

        session.hf_audio_q = asyncio.Queue()
        session.spawn(hands_free_processor(
            session, cfg, vad, smart_turn,
            effective_system_prompt=_effective_prompt(session, prompts),
        ))
        log.info("[%s] HF processor started", conn_id)

    # ── Main receive loop ─────────────────────────────────────────────────
    try:
        while not shutdown_event.is_set():
            msg = await ws.receive()

            if msg.get("type") == "websocket.disconnect":
                break

            if msg.get("type") == "websocket.receive" and "text" in msg:
                if len(msg["text"]) > MAX_JSON_MSG_SIZE:
                    log.warning("[%s] oversized JSON (%d bytes), dropping", conn_id, len(msg["text"]))
                    continue
                try:
                    data = json.loads(msg["text"])
                except json.JSONDecodeError:
                    continue
                await _handle_text_message(session, data, prompts)
                continue

            if msg.get("type") == "websocket.receive" and "bytes" in msg:
                audio_chunk = msg["bytes"]
                try:
                    for i in range(0, len(audio_chunk), VAD_SPLIT_SIZE):
                        chunk = pad_to_vad_window(audio_chunk[i:i + VAD_SPLIT_SIZE])
                        if session.mode == "hands_free":
                            assert session.hf_audio_q is not None
                            await session.hf_audio_q.put(chunk)
                        else:
                            session.audio_buffer.add(chunk)
                except Exception as e:
                    log.exception("[%s] audio chunk error: %s", conn_id, e)

    except WebSocketDisconnect:
        log.info("[%s] client disconnected", conn_id)
    except Exception as e:
        log.error("[%s] websocket error: %s", conn_id, e)
    finally:
        await session.to_state(ServerState.INTERRUPTED)
        await session.cancel_all()
        await sessions.remove(session)
        await session.to_state(ServerState.IDLE)
        log.info("[%s] connection closed", conn_id)


async def _handle_text_message(session: Session, data: dict, prompts: PromptStore):
    """Dispatch a parsed JSON message from the client."""
    msg_type = data.get("type")
    cfg = app.state.cfg

    if msg_type == "interrupt":
        if await session.try_interrupt():
            await _send(session.ws, InterruptAckMessage(request_id=data.get("request_id", "")))
            log.info("[%s] interrupt acknowledged", session.conn_id)
        return

    if msg_type == "end_recording":
        if data.get("history"):
            session.warn_client_history_once()
        audio_data = session.audio_buffer.take()
        log.debug("[%s] end_recording: %d audio bytes", session.conn_id, len(audio_data))
        if audio_data and session.is_idle:
            log.info("[%s] processing %d bytes", session.conn_id, len(audio_data))
            session.spawn(process_speech(
                session, cfg, audio_data,
                effective_system_prompt=_effective_prompt(session, prompts),
            ))
        return

    if msg_type == "tts_request":
        text = (data.get("text") or "").strip()
        if text:
            session.spawn(handle_tts_only(session, cfg, text))
        return

    if msg_type == "text_query":
        if data.get("history"):
            session.warn_client_history_once()
        text = (data.get("text") or "").strip()
        if text and session.is_idle:
            log.info("[%s] text_query: %.60s", session.conn_id, text)
            await _send(session.ws, TranscriptMessage(text=text))

            async def _run():
                full = await generate_response(
                    session, cfg, text,
                    effective_system_prompt=_effective_prompt(session, prompts),
                )
                if full:
                    session.append_turn(text, full)

            session.spawn(_run())
        return

    if msg_type == "ping":
        await _send(session.ws, {"type": "pong"})
        return

    if msg_type == "get_config":
        await _send(session.ws, ConfigMessage(
            system_prompt=prompts.effective,
            is_default=prompts.is_default,
        ))
        return

    if msg_type == "set_config":
        new_prompt = data.get("system_prompt")
        if new_prompt is not None:
            prompts.set(new_prompt)
            session.system_prompt = new_prompt
            await _send(session.ws, ConfigSavedMessage(system_prompt=new_prompt))
            log.info("[%s] system prompt updated (%d chars)", session.conn_id, len(new_prompt))
        else:
            prompts.reset()
            session.system_prompt = None
            await _send(session.ws, ConfigResetMessage(system_prompt=prompts.default))
            log.info("[%s] system prompt reset to default", session.conn_id)
        return
