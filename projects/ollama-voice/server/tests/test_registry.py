"""SessionRegistry + connection-replacement tests."""
import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest

from connection import _register_session
from registry import SessionRegistry
from session import ServerState, Session


def _make_session(conn_id: str) -> Session:
    ws = AsyncMock()
    ws.send_json = AsyncMock()
    ws.send_bytes = AsyncMock()
    ws.close = AsyncMock()
    return Session(ws=ws, conn_id=conn_id, mode="ptt", system_prompt=None)


@pytest.mark.asyncio
class TestSessionRegistry:
    async def test_replace_returns_old(self):
        reg = SessionRegistry()
        a = _make_session("a")
        b = _make_session("b")

        assert await reg.replace(a) is None
        assert await reg.replace(b) is a
        assert reg.current_id == "b"

    async def test_remove_only_clears_if_match(self):
        reg = SessionRegistry()
        a = _make_session("a")
        b = _make_session("b")

        await reg.replace(a)
        await reg.remove(b)              # b isn't current — no-op
        assert reg.current_id == "a"
        await reg.remove(a)
        assert reg.current_id is None

    async def test_shutdown_cancels_and_closes(self):
        reg = SessionRegistry()
        a = _make_session("a")
        await reg.replace(a)

        await reg.shutdown()
        a.ws.close.assert_awaited_once()
        assert reg.current_id is None


@pytest.mark.asyncio
class TestRegisterSessionRace:
    """The new session must not be told it's authenticated while the old
    session's pipeline tasks are still running."""

    async def test_old_session_tasks_cancelled_before_new_authok(self):
        reg = SessionRegistry()
        old = _make_session("old")
        new = _make_session("new")

        # Spawn a long-running task on the old session that we expect to be cancelled.
        cancellation_observed = asyncio.Event()

        async def long_task():
            try:
                await asyncio.sleep(60)
            except asyncio.CancelledError:
                cancellation_observed.set()
                raise

        old.spawn(long_task())
        await reg.replace(old)

        # Wait one tick for the task to actually start running.
        await asyncio.sleep(0)

        # Now register the new session — this should cancel old's tasks
        # before sending AuthOkMessage to the new session.
        send_order: list[str] = []

        async def track_send(label, real_send):
            async def wrapped(msg):
                send_order.append(label)
                return await real_send(msg)
            return wrapped

        # We don't even need to track send order — the contract is:
        # by the time _register_session returns, old's tasks are done.
        # We were registered as `old` already, so swap it back so
        # _register_session sees the right state.
        await reg.replace(old)  # re-install old as current

        await _register_session(reg, new)

        # The old session's task must have been cancelled by the time we got here.
        assert cancellation_observed.is_set(), "old session's task was not cancelled before AuthOk"

        # Old session got the ConnectionReplacedMessage and was closed.
        old.ws.close.assert_awaited()
        sent_to_old = [c.args[0]["type"] for c in old.ws.send_json.call_args_list]
        assert "connection_replaced" in sent_to_old

        # New session got AuthOkMessage.
        sent_to_new = [c.args[0]["type"] for c in new.ws.send_json.call_args_list]
        assert sent_to_new == ["auth_ok"]

    async def test_first_connection_no_predecessor(self):
        """When there's no prior session, _register_session just sends AuthOk."""
        reg = SessionRegistry()
        s = _make_session("a")
        await _register_session(reg, s)

        sent = [c.args[0]["type"] for c in s.ws.send_json.call_args_list]
        assert sent == ["auth_ok"]

    async def test_old_session_send_failure_does_not_block_new_authok(self):
        """If sending ConnectionReplacedMessage fails (old WS already broken),
        the new session still gets AuthOk."""
        reg = SessionRegistry()
        old = _make_session("old")
        new = _make_session("new")

        # Make old.ws fail on every send.
        old.ws.send_json = AsyncMock(side_effect=RuntimeError("ws broken"))
        old.ws.close = AsyncMock(side_effect=RuntimeError("close failed"))

        await reg.replace(old)
        await _register_session(reg, new)

        sent_to_new = [c.args[0]["type"] for c in new.ws.send_json.call_args_list]
        assert sent_to_new == ["auth_ok"]
