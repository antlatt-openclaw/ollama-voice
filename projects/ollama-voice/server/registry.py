"""Single-active-session registry."""

import asyncio
import logging

from session import ServerState, Session

log = logging.getLogger("server")


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

    async def shutdown(self, *, close_code: int = 1001, close_reason: str = "Server shutting down"):
        async with self._lock:
            session = self._current
            self._current = None
        if session is None:
            return
        await session.cancel_all()
        try:
            await session.ws.close(code=close_code, reason=close_reason)
        except Exception:
            pass
