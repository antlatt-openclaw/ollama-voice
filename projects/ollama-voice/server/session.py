"""Per-connection session state.

Each WebSocket gets one Session. State transitions are guarded by an
asyncio.Lock so the receive loop, response task, and hands-free processor
can't race each other.
"""

import asyncio
import logging
from enum import Enum
from typing import Literal

from fastapi import WebSocket

from audio import AudioBuffer

log = logging.getLogger("server")

# Maximum conversation history entries kept (server-owned, both modes).
MAX_HISTORY = 16

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

    # ── State transitions ─────────────────────────────────────────────────
    async def to_state(self, new: ServerState):
        async with self._state_lock:
            self.state = new

    async def try_interrupt(self) -> bool:
        """Mark interrupted iff currently processing or responding. Returns True if applied."""
        async with self._state_lock:
            if self.state in (ServerState.PROCESSING, ServerState.RESPONDING):
                self.state = ServerState.INTERRUPTED
                return True
            return False

    @property
    def is_interrupted(self) -> bool:
        return self.state == ServerState.INTERRUPTED

    @property
    def is_idle(self) -> bool:
        return self.state == ServerState.IDLE

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
