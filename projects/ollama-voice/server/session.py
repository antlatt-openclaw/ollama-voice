"""Per-connection session state.

Each WebSocket gets one Session. Plain assignments to `state` are safe
under cooperative asyncio. The state lock is only used by try_interrupt(),
which needs to atomically check-and-set on PROCESSING/RESPONDING transitions.
"""

import asyncio
import logging
from contextlib import asynccontextmanager
from enum import Enum
from typing import Literal

from fastapi import WebSocket

from audio_buffer import AudioBuffer

log = logging.getLogger("server")

# Maximum conversation history entries kept (server-owned, both modes).
MAX_HISTORY = 16

# WebSocket binary chunk size for outgoing audio.
AUDIO_CHUNK_SIZE = 4096

# Max queued VAD-window chunks for hands-free input. ~32s at 32ms/chunk.
# When full, the receive loop drops the oldest chunk before enqueueing.
HF_QUEUE_MAX = 1000

Mode = Literal["ptt", "hands_free"]


class ServerState(Enum):
    IDLE = "idle"
    PROCESSING = "processing"
    RESPONDING = "responding"
    INTERRUPTED = "interrupted"


class Session:
    """One active WebSocket connection's state."""

    def __init__(
        self,
        ws: WebSocket,
        conn_id: str,
        mode: Mode,
        system_prompt: str | None,
    ):
        self.ws = ws
        self.conn_id = conn_id
        self.mode: Mode = mode
        self.system_prompt = system_prompt  # None = use server default

        self.state = ServerState.IDLE
        self._state_lock = asyncio.Lock()

        self.audio_buffer = AudioBuffer()
        self.history: list[dict] = []
        self.hf_audio_q: asyncio.Queue | None = None  # set if mode == hands_free

        self._tasks: set[asyncio.Task] = set()
        self._client_history_warned = False
        self._hf_queue_drop_warned = False

    # ── State transitions ─────────────────────────────────────────────────
    # Plain reads/writes of `state` are fine — only try_interrupt() needs CAS.

    async def try_interrupt(self) -> bool:
        """Mark interrupted iff currently processing or responding. Returns True if applied."""
        async with self._state_lock:
            if self.state in (ServerState.PROCESSING, ServerState.RESPONDING):
                self.state = ServerState.INTERRUPTED
                return True
            return False

    @asynccontextmanager
    async def in_state(self, state: ServerState):
        """Set state on entry; force IDLE on exit (normal or exception).

        Use this around any pipeline stage that should be guaranteed to leave
        the session idle when it ends, regardless of how it ends.
        """
        self.state = state
        try:
            yield
        finally:
            self.state = ServerState.IDLE

    @property
    def is_interrupted(self) -> bool:
        return self.state == ServerState.INTERRUPTED

    @property
    def is_idle(self) -> bool:
        return self.state == ServerState.IDLE

    # ── Outgoing messages ────────────────────────────────────────────────
    async def send(self, msg) -> None:
        """Send a Pydantic message or raw dict over this session's WebSocket."""
        try:
            data = msg.model_dump() if hasattr(msg, "model_dump") else msg
            await self.ws.send_json(data)
        except Exception as e:
            log.warning("[%s] send error: %s", self.conn_id, e)

    async def send_if_active(self, msg) -> None:
        """send() that drops silently when the session has been interrupted."""
        if self.is_interrupted:
            return
        await self.send(msg)

    async def send_audio(self, pcm: bytes, *, chunk_size: int = AUDIO_CHUNK_SIZE) -> bool:
        """Stream PCM bytes as binary WS frames. Returns False if interrupted or send failed."""
        for i in range(0, len(pcm), chunk_size):
            if self.is_interrupted:
                return False
            try:
                await self.ws.send_bytes(pcm[i:i + chunk_size])
            except Exception as e:
                log.warning("[%s] send_audio error: %s", self.conn_id, e)
                return False
        return True

    # ── History management ───────────────────────────────────────────────
    def append_turn(self, user_text: str, assistant_text: str):
        self.history.append({"role": "user", "content": user_text})
        self.history.append({"role": "assistant", "content": assistant_text})
        if len(self.history) > MAX_HISTORY:
            del self.history[:-MAX_HISTORY]

    def history_snapshot(self) -> list[dict]:
        return list(self.history)

    def warn_client_history_once(self):
        if not self._client_history_warned:
            self._client_history_warned = True
            log.info(
                "[%s] client sent history field — server now owns history; ignoring",
                self.conn_id,
            )

    def warn_hf_queue_drop_once(self):
        if not self._hf_queue_drop_warned:
            self._hf_queue_drop_warned = True
            log.warning(
                "[%s] HF queue full — dropping oldest audio (will not warn again for this connection)",
                self.conn_id,
            )

    # ── Task lifecycle ────────────────────────────────────────────────────
    def spawn(self, coro) -> asyncio.Task:
        """Create a tracked task for this session."""
        task = asyncio.create_task(coro)
        self._tasks.add(task)

        def _on_done(t):
            self._tasks.discard(t)
            exc = t.exception()
            if exc is not None and not isinstance(exc, asyncio.CancelledError):
                log.error("[%s] task failed: %s", self.conn_id, exc, exc_info=exc)

        task.add_done_callback(_on_done)
        return task

    async def cancel_all(self, timeout: float = 2.0):
        for task in list(self._tasks):
            if not task.done():
                task.cancel()
        if self._tasks:
            try:
                await asyncio.wait_for(
                    asyncio.gather(*self._tasks, return_exceptions=True),
                    timeout=timeout,
                )
            except asyncio.TimeoutError:
                log.warning("[%s] tasks did not finish within %.1fs", self.conn_id, timeout)
