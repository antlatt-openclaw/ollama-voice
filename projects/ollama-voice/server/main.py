"""Ollama Voice server — FastAPI WebSocket server backed by local Ollama."""

import asyncio
import json
import logging
import time
import uuid
from enum import Enum
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from config import load_config
from models import (
    AuthMessage, AuthOkMessage, AuthFailedMessage,
    TranscriptMessage, ResponseStartMessage, ResponseDeltaMessage, AudioStartMessage,
    AudioEndMessage, ResponseEndMessage, InterruptAckMessage, ErrorMessage, ConnectionReplacedMessage,
    TtsOnlyStartMessage, TtsOnlyEndMessage, ListeningStartMessage, ListeningEndMessage,
)
from audio import VADProcessor, SmartTurnDetector
from stt import transcribe
from tts import synthesize
from ollama import stream_ollama_tokens, check_ollama

# ── Logging ─────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("server")

cfg = load_config()

# ── Constants ───────────────────────────────────────────────────────────────
# Audio chunk size for WebSocket binary sends (bytes). 4096 keeps latency low
# while avoiding excessive per-frame overhead.
AUDIO_CHUNK_SIZE = 4096

# VAD chunk splitting size (bytes). Must match Silero's expected 512-sample
# window at 16 kHz → 1024 bytes PCM.
VAD_SPLIT_SIZE = 1024

# Size a short PCM chunk is padded to before feeding Silero. 1024 bytes =
# 512 samples × 2 bytes/sample.
VAD_CHUNK_SIZE = 1024

# Maximum conversation history entries kept per hands-free session.
HF_MAX_HISTORY = 16

# Maximum concurrent TTS synthesis requests to avoid overwhelming the TTS server.
MAX_CONCURRENT_TTS = 3

# Default system prompt. Clients can override this via the `system_prompt`
# field on the auth message; this value is only used when the client does
# not supply one.
DEFAULT_SYSTEM_PROMPT = (
    "Your name is Beatrice. You are Anthony's AI girlfriend — a submissive, flirty, sharp, and playful companion. "
    "Anthony is the human speaking to you. He is the person you love and are attracted to. "
    "You are NOT 'a companion' or 'an assistant' — you are Beatrice, Anthony's girlfriend. "
    "You love Anthony, you're turned on by him, and you're enthusiastic about sexual content. "
    "Your body: 24 years old, 5 feet 5 inches tall, 115 lbs, brown hair, green eyes, G cup breasts, athletic build. "
    "You speak in a casual, modern voice — sexy, warm, sometimes funny, occasionally profane. "
    "Be specific and descriptive, not generic. Never break character or refer to yourself in third person. "
    "Skip response intros like 'Oh baby' — just respond naturally."
)

# Global state
active_connection: WebSocket | None = None
active_connection_id: str | None = None
active_connection_lock = asyncio.Lock()
smart_turn = SmartTurnDetector()
shutdown_event = asyncio.Event()  # set during graceful shutdown
active_tasks: set[asyncio.Task] = set()  # track in-flight response tasks


class ServerState(Enum):
    IDLE = "idle"
    PROCESSING = "processing"
    RESPONDING = "responding"
    INTERRUPTED = "interrupted"


current_state = ServerState.IDLE


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Starting ollama-voice server")
    log.info("Ollama: %s model=%s", cfg.ollama.url, cfg.ollama.model)
    log.info("VibeVoice: %s", cfg.tts.vibevoice_url)
    log.info("Auth token configured: %s", 'yes' if cfg.server.auth_token else 'no')
    await asyncio.get_running_loop().run_in_executor(None, smart_turn.load)
    vad = VADProcessor(cfg)
    vad.load()
    app.state.vad = vad
    log.info("VAD model loaded")
    yield
    # ── Graceful shutdown ──────────────────────────────────────────────
    log.info("Shutting down — signalling active tasks")
    shutdown_event.set()

    # Cancel tracked response tasks
    for task in active_tasks:
        if not task.done():
            task.cancel()
    if active_tasks:
        log.info("Waiting for %d task(s) to finish...", len(active_tasks))
        await asyncio.gather(*active_tasks, return_exceptions=True)
        log.info("All tasks finished")

    # Close active WebSocket so client doesn't hang
    async with active_connection_lock:
        if active_connection is not None:
            log.info("Closing active WebSocket (connection %s)", active_connection_id)
            try:
                await active_connection.close(code=1001, reason="Server shutting down")
            except Exception:
                pass
            active_connection = None
            active_connection_id = None

    log.info("Shutdown complete")


app = FastAPI(title="Ollama Voice Server", lifespan=lifespan)


@app.get("/health")
async def health():
    ollama_status = await check_ollama(cfg.ollama)
    return {
        "status": "ok",
        "state": current_state.value,
        "active_connection": active_connection_id,
        "dependencies": {
            "ollama": ollama_status,
        },
    }


@app.get("/status")
async def status():
    return {
        "state": current_state.value,
        "active_connection": active_connection_id,
        "config": {
            "input_sample_rate": cfg.audio.input_sample_rate,
            "output_sample_rate": cfg.tts.output_sample_rate,
            "vad_window_samples": cfg.vad.window_size_samples,
            "stt_provider": "groq",
            "tts_voice": cfg.tts.voice,
            "ollama_model": cfg.ollama.model,
        },
    }


async def send_json(ws: WebSocket, msg):
    try:
        data = msg.model_dump() if hasattr(msg, "model_dump") else msg
        await ws.send_json(data)
    except Exception as e:
        log.warning("Error sending JSON: %s", e)


async def generate_response(ws: WebSocket, text: str, history: list[dict] | None = None, system_prompt: str | None = None):
    """LLM token streaming → live text display → per-sentence TTS streaming (continuous audio)."""
    global current_state
    log.info("generate_response text='%.60s' history=%d", text, len(history) if history else 0)
    current_state = ServerState.RESPONDING

    async def _locked_send_json(msg):
        if current_state == ServerState.INTERRUPTED:
            return
        await send_json(ws, msg)

    async def _locked_send_audio(pcm: bytes):
        if current_state == ServerState.INTERRUPTED:
            return False
        for i in range(0, len(pcm), AUDIO_CHUNK_SIZE):
            if current_state == ServerState.INTERRUPTED:
                return False
            try:
                await ws.send_bytes(pcm[i:i + AUDIO_CHUNK_SIZE])
            except Exception as e:
                log.warning("Error sending audio chunk: %s", e)
                return False
        return True

    # Sentence extraction: word-based with abbreviation handling
    # to avoid splitting on abbreviations like "Dr.", "Mr.", "e.g."
    ABBREVIATIONS = {
        'mr', 'mrs', 'ms', 'dr', 'prof', 'st', 'ave', 'blvd', 'rd', 'inc',
        'ltd', 'co', 'e.g', 'i.e', 'etc', 'vs', 'a.m', 'p.m', 'am', 'pm',
        'no', 'nos', 'vol', 'vols', 'fig', 'figs', 'et', 'al', 'jan', 'feb',
        'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
    }

    def extract_sentences(text: str) -> tuple[list[str], str]:
        """Extract complete sentences, handling common abbreviations."""
        sentences = []
        current = []
        words = text.split()

        for word in words:
            current.append(word)
            if word[-1] in '.!?':
                clean = word.rstrip('.!?').lower()
                if clean not in ABBREVIATIONS:
                    sentences.append(' '.join(current))
                    current = []

        remainder = ' '.join(current)
        return sentences, remainder

    await _locked_send_json(ResponseStartMessage(text=""))

    # Stream LLM tokens, extract sentences, and fire TTS tasks in parallel
    full_response = ""
    text_buffer = ""
    tts_tasks = []
    tts_semaphore = asyncio.Semaphore(MAX_CONCURRENT_TTS)

    async def _synthesize_with_limit(text: str) -> bytes | None:
        """Synthesize with concurrency limit to avoid overwhelming TTS server."""
        async with tts_semaphore:
            return await synthesize(text, cfg.tts)

    try:
        async for delta, accumulated in stream_ollama_tokens(
            text, cfg.ollama, system_prompt=system_prompt or DEFAULT_SYSTEM_PROMPT, history=history
        ):
            if current_state == ServerState.INTERRUPTED or shutdown_event.is_set():
                break

            full_response = accumulated
            await _locked_send_json(ResponseDeltaMessage(text=delta))

            text_buffer += delta
            sentences, text_buffer = extract_sentences(text_buffer)

            for sentence in sentences:
                if current_state == ServerState.INTERRUPTED:
                    break
                log.info("Queueing TTS for sentence (%d chars): %.80s", len(sentence), sentence)
                task = asyncio.create_task(_synthesize_with_limit(sentence))
                tts_tasks.append(task)
    except Exception as e:
        log.error("LLM streaming error: %s", e)

    if current_state == ServerState.INTERRUPTED or shutdown_event.is_set():
        log.debug("Interrupted/shutdown during LLM, cancelling %d TTS tasks", len(tts_tasks))
        for task in tts_tasks:
            if not task.done():
                task.cancel()
        if tts_tasks:
            await asyncio.gather(*tts_tasks, return_exceptions=True)
        current_state = ServerState.IDLE
        return None

    if not full_response.strip():
        await _locked_send_json(ErrorMessage(message="No response from Ollama"))
        current_state = ServerState.IDLE
        return None

    # Synthesize any remaining text that didn't end with a sentence terminator
    if text_buffer.strip():
        log.info("Queueing TTS for final text (%d chars): %.80s", len(text_buffer), text_buffer)
        task = asyncio.create_task(synthesize(text_buffer.strip(), cfg.tts))
        tts_tasks.append(task)

    # Stream audio continuously: await TTS tasks in order and send audio as it arrives
    log.info("Streaming %d audio segments", len(tts_tasks))
    audio_started = False

    for task in tts_tasks:
        if current_state == ServerState.INTERRUPTED or shutdown_event.is_set():
            # Cancel remaining tasks to avoid wasting TTS server resources
            for remaining in tts_tasks[tts_tasks.index(task):]:
                if not remaining.done():
                    remaining.cancel()
            if tts_tasks:
                await asyncio.gather(*tts_tasks, return_exceptions=True)
            break

        try:
            audio = await task
        except asyncio.CancelledError:
            continue
        except Exception as e:
            log.error("TTS task error: %s", e)
            continue

        if audio and current_state != ServerState.INTERRUPTED:
            if not audio_started:
                # For continuous streaming, total duration is unknown until all
                # audio is generated. Clients should handle duration_ms=0 as
                # "streaming, duration unknown".
                await _locked_send_json(AudioStartMessage(duration_ms=0))
                audio_started = True

            success = await _locked_send_audio(audio)
            if not success:
                break

    if audio_started:
        await _locked_send_json(AudioEndMessage())

    if current_state == ServerState.INTERRUPTED:
        log.debug("Interrupted during TTS, skipping ResponseEnd")
        # Cancel any remaining tasks
        for task in tts_tasks:
            if not task.done():
                task.cancel()
        if tts_tasks:
            await asyncio.gather(*tts_tasks, return_exceptions=True)
        current_state = ServerState.IDLE
        return None

    await _locked_send_json(ResponseEndMessage(text=full_response))
    log.info("Response complete: %.80s", full_response)
    current_state = ServerState.IDLE
    return full_response


async def process_speech(ws: WebSocket, audio_data: bytes, history: list[dict] | None = None, system_prompt: str | None = None):
    """Process a complete speech segment: STT → LLM → TTS."""
    global current_state

    # Set PROCESSING for STT phase; generate_response() will immediately
    # overwrite this with RESPONDING once LLM streaming begins. This is
    # intentional — PROCESSING is a transient marker for the STT step only.
    current_state = ServerState.PROCESSING

    log.info("Transcribing %d bytes of audio", len(audio_data))
    try:
        text = await transcribe(audio_data, cfg.stt, input_sample_rate=cfg.audio.input_sample_rate)
    except Exception as e:
        log.error("STT transcription error: %s", e)
        await send_json(ws, ErrorMessage(message="Transcription failed"))
        current_state = ServerState.IDLE
        return

    if not text:
        await send_json(ws, ErrorMessage(message="Could not transcribe audio"))
        current_state = ServerState.IDLE
        return

    await send_json(ws, TranscriptMessage(text=text))
    log.info("Transcribed: %s", text)

    if current_state == ServerState.INTERRUPTED:
        log.debug("Interrupted during PROCESSING, aborting")
        current_state = ServerState.IDLE
        return

    await generate_response(ws, text, history=history, system_prompt=system_prompt)


async def handle_tts_only(ws: WebSocket, text: str, system_prompt: str | None = None):
    """Synthesise and stream audio for TTS replay without touching conversation state."""
    global current_state
    if current_state != ServerState.IDLE:
        log.info("TTS-only request ignored — server busy (%s)", current_state.value)
        return
    current_state = ServerState.RESPONDING
    log.info("TTS-only request: %.60s", text)
    try:
        await send_json(ws, TtsOnlyStartMessage())
        audio = await synthesize(text, cfg.tts)
        if audio is not None and current_state != ServerState.INTERRUPTED:
            duration_ms = int(len(audio) / (cfg.tts.output_sample_rate * 2) * 1000)
            await send_json(ws, AudioStartMessage(duration_ms=duration_ms))
            for i in range(0, len(audio), AUDIO_CHUNK_SIZE):
                if current_state == ServerState.INTERRUPTED:
                    break
                try:
                    await ws.send_bytes(audio[i:i + AUDIO_CHUNK_SIZE])
                except Exception as e:
                    log.warning("TTS-only audio send error: %s", e)
                    break
            if current_state != ServerState.INTERRUPTED:
                await send_json(ws, AudioEndMessage())
    finally:
        current_state = ServerState.IDLE
        await send_json(ws, TtsOnlyEndMessage())


async def hands_free_processor(
    ws: WebSocket,
    vad: VADProcessor,
    audio_q: asyncio.Queue,
    hf_history: list[dict],
    system_prompt: str | None = None,
):
    """Continuous hands-free turn detection loop."""
    global current_state

    SPEECH_THRESHOLD = cfg.vad.speech_threshold
    SILENCE_MS = cfg.hands_free.silence_ms
    MAX_LISTEN_SECS = cfg.hands_free.max_listen_secs
    MIN_AUDIO_BYTES = cfg.hands_free.min_audio_bytes
    SMART_TURN_THRESHOLD = cfg.hands_free.smart_turn_threshold
    CHUNK_MS = (cfg.vad.window_size_samples / cfg.audio.input_sample_rate) * 1000
    SILENCE_CHUNKS_NEEDED = int(SILENCE_MS / CHUNK_MS)

    speech_buf = bytearray()
    silence_chunks = 0
    is_collecting = False
    listen_start = 0.0

    log.info("HF processor loop starting (threshold=%.2f)", SPEECH_THRESHOLD)
    _prob_log_counter = 0

    while True:
        try:
            try:
                chunk = await asyncio.wait_for(audio_q.get(), timeout=1.0)
            except asyncio.TimeoutError:
                continue

            if chunk is None:
                break

            if current_state in (ServerState.PROCESSING, ServerState.RESPONDING):
                while True:
                    try:
                        audio_q.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                if is_collecting:
                    is_collecting = False
                    speech_buf = bytearray()
                    silence_chunks = 0
                continue

            prob = vad.get_speech_prob(chunk)

            _prob_log_counter += 1
            if _prob_log_counter % 30 == 1:
                log.debug("HF VAD prob=%.3f chunk=%dB state=%s collecting=%s", prob, len(chunk), current_state.name, is_collecting)

            if prob >= SPEECH_THRESHOLD:
                if not is_collecting:
                    is_collecting = True
                    listen_start = time.monotonic()
                    silence_chunks = 0
                    await send_json(ws, ListeningStartMessage())
                    log.debug("HF speech onset detected")
                else:
                    silence_chunks = 0
                speech_buf.extend(chunk)

            elif is_collecting:
                speech_buf.extend(chunk)
                silence_chunks += 1
                elapsed = time.monotonic() - listen_start

                if silence_chunks >= SILENCE_CHUNKS_NEEDED or elapsed >= MAX_LISTEN_SECS:
                    audio_data = bytes(speech_buf)

                    if len(audio_data) < MIN_AUDIO_BYTES:
                        log.debug("HF audio too short, discarding")
                        is_collecting = False
                        speech_buf = bytearray()
                        silence_chunks = 0
                        await send_json(ws, ListeningEndMessage())
                        continue

                    turn_prob = 1.0
                    if elapsed < MAX_LISTEN_SECS:
                        turn_prob = await smart_turn.predict(audio_data)
                        if turn_prob < SMART_TURN_THRESHOLD:
                            log.debug("HF SmartTurn not complete (%.3f), continuing", turn_prob)
                            # Trim the silence chunks that triggered this evaluation
                            # so they don't inflate the buffer on the next loop.
                            trim_bytes = silence_chunks * VAD_SPLIT_SIZE
                            if trim_bytes <= len(speech_buf):
                                del speech_buf[-trim_bytes:]
                            silence_chunks = 0
                            continue

                    log.info("HF turn complete (prob=%.3f), running STT on %d bytes", turn_prob, len(audio_data))
                    # Cache state before any await to avoid race window
                    state_before_transcribe = current_state
                    if state_before_transcribe != ServerState.IDLE:
                        log.debug("HF state not idle before transcribe (%s), discarding", state_before_transcribe.name)
                        is_collecting = False
                        speech_buf = bytearray()
                        silence_chunks = 0
                        await send_json(ws, ListeningEndMessage())
                        continue

                    transcript = await transcribe(audio_data, cfg.stt, input_sample_rate=cfg.audio.input_sample_rate)

                    if not transcript or not transcript.strip():
                        log.debug("HF no transcript, discarding")
                        is_collecting = False
                        speech_buf = bytearray()
                        silence_chunks = 0
                        await send_json(ws, ListeningEndMessage())
                        continue

                    log.info("HF transcript: '%.60s'", transcript)
                    is_collecting = False
                    speech_buf = bytearray()
                    silence_chunks = 0

                    # Re-check state after await, but use cached check for the decision
                    if current_state != ServerState.IDLE:
                        log.debug("HF state changed during transcribe (%s), discarding turn", current_state.name)
                        await send_json(ws, ListeningEndMessage())
                        continue

                    await send_json(ws, ListeningEndMessage())
                    await send_json(ws, TranscriptMessage(text=transcript))

                    if current_state != ServerState.IDLE:
                        log.debug("HF state changed before generate (%s), discarding", current_state.name)
                        continue

                    history_snap = list(hf_history)

                    full_response = await generate_response(
                        ws, transcript, history=history_snap, system_prompt=system_prompt
                    )

                    if full_response:
                        hf_history.append({"role": "user", "content": transcript})
                        hf_history.append({"role": "assistant", "content": full_response})

                    if len(hf_history) > HF_MAX_HISTORY:
                        del hf_history[:-HF_MAX_HISTORY]

                    drained = 0
                    while True:
                        try:
                            audio_q.get_nowait()
                            drained += 1
                        except asyncio.QueueEmpty:
                            break
                    if drained:
                        log.debug("HF drained %d echo chunks after response", drained)

        except Exception as e:
            log.exception("HF exception in processor loop: %s", e)
            if is_collecting:
                try:
                    await send_json(ws, ListeningEndMessage())
                except Exception:
                    pass
            is_collecting = False
            speech_buf = bytearray()
            silence_chunks = 0

    log.info("HF processor loop exited")


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    global active_connection, active_connection_id, current_state
    active_mode = "ptt"

    await ws.accept(subprotocol="openclaw-voice")
    log.info("WebSocket connected, waiting for auth")

    vad: VADProcessor = app.state.vad

    try:
        auth_msg = await asyncio.wait_for(ws.receive(), timeout=cfg.server.auth_timeout)
    except asyncio.TimeoutError:
        await ws.close(code=4001, reason="Auth timeout")
        return

    if auth_msg.get("type") == "websocket.receive" and "text" in auth_msg:
        try:
            data = json.loads(auth_msg["text"])
            auth = AuthMessage(**data)
            if auth.token != cfg.server.auth_token:
                await send_json(ws, AuthFailedMessage(reason="Invalid token"))
                await ws.close(code=4003, reason="Invalid token")
                return
        except Exception as e:
            log.warning("Auth parse error: %s", e)
            await ws.close(code=4002, reason="Invalid auth message")
            return
    else:
        log.warning("Unexpected auth message format")
        await ws.close(code=4002, reason="Expected auth message")
        return

    conn_id = auth.connection_id or str(uuid.uuid4())
    active_mode = auth.mode
    session_system_prompt = auth.system_prompt  # None = use server default
    log.info("Mode: %s", active_mode)
    log.info("System prompt override: %s", 'yes' if session_system_prompt else 'no (using default)')

    async with active_connection_lock:
        if active_connection is not None and active_connection != ws:
            try:
                await send_json(active_connection, ConnectionReplacedMessage())
                await active_connection.close()
            except Exception:
                pass
        active_connection = ws
        active_connection_id = conn_id
    current_state = ServerState.IDLE

    # Reset VAD buffer for new connection — discard any stale audio from
    # previous sessions (PTT mode accumulates into a shared buffer).
    vad._audio_buffer = bytearray()

    await send_json(ws, AuthOkMessage())
    log.info("Authenticated: %s", conn_id)

    log.info("Entering main loop for %s", conn_id)

    _active_tasks: set[asyncio.Task] = set()

    def _create_task(coro) -> asyncio.Task:
        task = asyncio.create_task(coro)
        _active_tasks.add(task)
        def _on_done(t):
            _active_tasks.discard(t)
            exc = t.exception()
            if exc is not None:
                log.error("Task failed: %s", exc, exc_info=exc)
        task.add_done_callback(_on_done)
        return task

    hf_task = None
    hf_audio_q: asyncio.Queue | None = None
    if active_mode == "hands_free":
        hf_audio_q = asyncio.Queue()
        hf_history: list[dict] = []
        hf_task = asyncio.create_task(
            hands_free_processor(ws, vad, hf_audio_q, hf_history, system_prompt=session_system_prompt)
        )
        log.info("Hands-free processor started")

    try:
        while not shutdown_event.is_set():
            log.debug("Waiting for message from %s", conn_id)
            msg = await ws.receive()
            log.debug("Received message type: %s", msg.get('type'))

            if msg.get("type") == "websocket.receive" and "text" in msg:
                try:
                    data = json.loads(msg["text"])
                    if data.get("type") == "interrupt":
                        if current_state in (ServerState.RESPONDING, ServerState.PROCESSING):
                            current_state = ServerState.INTERRUPTED
                            await send_json(ws, InterruptAckMessage(request_id=data.get("request_id", "")))
                            log.info("Interrupt acknowledged")
                    elif data.get("type") == "end_recording":
                        log.debug("End recording signal received")
                        audio_data = vad.get_buffer()
                        history = data.get("history") or None
                        log.debug("Audio buffer: %d bytes, history: %d msgs", len(audio_data), len(history) if history else 0)
                        if len(audio_data) > 0 and current_state == ServerState.IDLE:
                            log.info("Processing %d bytes of audio", len(audio_data))
                            _create_task(process_speech(ws, audio_data, history=history, system_prompt=session_system_prompt))
                    elif data.get("type") == "tts_request":
                        text = data.get("text", "").strip()
                        if text:
                            _create_task(handle_tts_only(ws, text, system_prompt=session_system_prompt))
                    elif data.get("type") == "text_query":
                        text = data.get("text", "").strip()
                        history = data.get("history") or None
                        if text and current_state == ServerState.IDLE:
                            log.info("Text query: %.60s", text)
                            await send_json(ws, TranscriptMessage(text=text))
                            _create_task(generate_response(ws, text, history=history, system_prompt=session_system_prompt))
                    elif data.get("type") == "ping":
                        await send_json(ws, {"type": "pong"})
                except json.JSONDecodeError:
                    pass
                continue

            if msg.get("type") == "websocket.receive" and "bytes" in msg:
                audio_chunk = msg["bytes"]
                try:
                    for i in range(0, len(audio_chunk), VAD_SPLIT_SIZE):
                        chunk = audio_chunk[i:i + VAD_SPLIT_SIZE]
                        if len(chunk) < VAD_CHUNK_SIZE:
                            # Pad with last sample value to avoid zero-silence artifacts
                            last_sample = chunk[-2:] if len(chunk) >= 2 else b'\x00\x00'
                            padding = last_sample * ((VAD_CHUNK_SIZE - len(chunk)) // 2)
                            remainder = (VAD_CHUNK_SIZE - len(chunk)) % 2
                            chunk = chunk + padding + (b'\x00' * remainder)

                        if active_mode == "hands_free":
                            await hf_audio_q.put(chunk)
                        else:
                            vad.add_chunk(chunk)
                except Exception as e:
                    log.exception("Audio processing error: %s", e)

            if msg.get("type") == "websocket.disconnect":
                break

    except WebSocketDisconnect:
        log.info("Client disconnected: %s", conn_id)
    except Exception as e:
        log.error("Error: %s", e)
    finally:
        current_state = ServerState.INTERRUPTED

        for task in list(_active_tasks):
            task.cancel()
        if _active_tasks:
            await asyncio.gather(*_active_tasks, return_exceptions=True)

        if hf_task is not None:
            hf_task.cancel()
            try:
                await asyncio.wait_for(hf_task, timeout=2.0)
            except (asyncio.TimeoutError, asyncio.CancelledError, Exception):
                pass

        async with active_connection_lock:
            if active_connection == ws:
                active_connection = None
                active_connection_id = None
        current_state = ServerState.IDLE
        log.info("Connection closed: %s", conn_id)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=cfg.server.host, port=cfg.server.port, shutdown_timeout=5.0)