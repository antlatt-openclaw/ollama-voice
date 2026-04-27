"""FastAPI app, lifespan, and HTTP/WebSocket routes."""

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket

from config import load_config
from connection import ConnectionDeps, run_session
from ollama import check_ollama
from prompts import PromptStore, load_default_prompt
from registry import SessionRegistry
from smart_turn import SmartTurnDetector
from vad import VAD

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("server")

cfg = load_config()


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Starting ollama-voice server")
    log.info("Ollama: %s model=%s", cfg.ollama.url, cfg.ollama.model)
    log.info("VibeVoice: %s", cfg.tts.vibevoice_url)
    log.info("Auth token configured: %s", 'yes' if cfg.server.auth_token else 'no')

    prompts = PromptStore(default=load_default_prompt())
    prompts.load()
    if not prompts.is_default:
        log.info("Loaded custom system prompt (%d chars)", len(prompts.effective))
    else:
        log.info("Using default system prompt")

    # VAD + SmartTurn lazy-load on first hands-free connection.
    app.state.deps = ConnectionDeps(
        cfg=cfg,
        sessions=SessionRegistry(),
        prompts=prompts,
        vad=VAD(sample_rate=cfg.audio.input_sample_rate),
        smart_turn=SmartTurnDetector(),
        shutdown_event=asyncio.Event(),
    )

    yield

    log.info("Shutting down — signalling sessions")
    app.state.deps.shutdown_event.set()
    await app.state.deps.sessions.shutdown()
    log.info("Shutdown complete")


app = FastAPI(title="Ollama Voice Server", lifespan=lifespan)


@app.get("/health")
async def health():
    ollama_status = await check_ollama(cfg.ollama)
    return {
        "status": "ok",
        "state": app.state.deps.sessions.current_state,
        "active_connection": app.state.deps.sessions.current_id,
        "dependencies": {"ollama": ollama_status},
    }


@app.get("/status")
async def status():
    return {
        "state": app.state.deps.sessions.current_state,
        "active_connection": app.state.deps.sessions.current_id,
        "config": {
            "input_sample_rate": cfg.audio.input_sample_rate,
            "output_sample_rate": cfg.tts.output_sample_rate,
            "vad_window_samples": cfg.vad.window_size_samples,
            "stt_provider": "groq",
            "tts_voice": cfg.tts.voice,
            "ollama_model": cfg.ollama.model,
        },
    }


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await run_session(ws, app.state.deps)
