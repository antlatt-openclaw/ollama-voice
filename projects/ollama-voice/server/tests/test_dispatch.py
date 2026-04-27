"""Text-message dispatch routing tests."""
import pytest
from unittest.mock import AsyncMock, MagicMock

from handlers import dispatch_text
from main import cfg
from prompts import PromptStore
from session import Session


def _make_session(*, idle: bool = True):
    """Real Session with stubbed ws/send/spawn."""
    s = Session(ws=MagicMock(), conn_id="t", mode="ptt", system_prompt=None)
    s.send = AsyncMock()
    # Make spawn a no-op that closes the coroutine to avoid "never awaited" warnings.
    def _spawn(coro):
        coro.close()
        return MagicMock()
    s.spawn = MagicMock(side_effect=_spawn)
    return s


@pytest.mark.asyncio
class TestDispatchUnknown:
    async def test_unknown_type_dropped(self):
        s = _make_session()
        await dispatch_text(s, {"type": "bogus"}, cfg, PromptStore())
        s.send.assert_not_called()

    async def test_missing_type_dropped(self):
        s = _make_session()
        await dispatch_text(s, {"foo": "bar"}, cfg, PromptStore())
        s.send.assert_not_called()


@pytest.mark.asyncio
class TestDispatchPing:
    async def test_ping_returns_pong(self):
        s = _make_session()
        await dispatch_text(s, {"type": "ping"}, cfg, PromptStore())
        s.send.assert_called_once_with({"type": "pong"})


@pytest.mark.asyncio
class TestDispatchInterrupt:
    async def test_interrupt_when_busy_acks(self):
        s = _make_session()
        s.try_interrupt = AsyncMock(return_value=True)
        await dispatch_text(s, {"type": "interrupt", "request_id": "r1"}, cfg, PromptStore())
        s.send.assert_called_once()
        ack = s.send.call_args[0][0]
        assert ack.request_id == "r1"

    async def test_interrupt_when_idle_no_ack(self):
        s = _make_session()
        s.try_interrupt = AsyncMock(return_value=False)
        await dispatch_text(s, {"type": "interrupt"}, cfg, PromptStore())
        s.send.assert_not_called()

    async def test_interrupt_default_request_id_empty(self):
        s = _make_session()
        s.try_interrupt = AsyncMock(return_value=True)
        await dispatch_text(s, {"type": "interrupt"}, cfg, PromptStore())
        ack = s.send.call_args[0][0]
        assert ack.request_id == ""


@pytest.mark.asyncio
class TestDispatchConfig:
    async def test_get_config_returns_current_state(self):
        s = _make_session()
        prompts = PromptStore()
        await dispatch_text(s, {"type": "get_config"}, cfg, prompts)
        msg = s.send.call_args[0][0]
        assert msg.system_prompt == prompts.effective
        assert msg.is_default is True

    async def test_set_config_saves_prompt(self, tmp_path, monkeypatch):
        import persist
        monkeypatch.setattr(persist, "DATA_DIR", tmp_path)
        monkeypatch.setattr(persist, "SETTINGS_FILE", tmp_path / "settings.json")

        s = _make_session()
        prompts = PromptStore()
        await dispatch_text(
            s, {"type": "set_config", "system_prompt": "be terse"}, cfg, prompts,
        )
        assert s.system_prompt == "be terse"
        assert prompts.effective == "be terse"
        assert not prompts.is_default

    async def test_set_config_null_prompt_resets(self, tmp_path, monkeypatch):
        import persist
        monkeypatch.setattr(persist, "DATA_DIR", tmp_path)
        monkeypatch.setattr(persist, "SETTINGS_FILE", tmp_path / "settings.json")

        s = _make_session()
        s.system_prompt = "stale override"
        prompts = PromptStore()
        prompts._persisted = "stale persisted"

        await dispatch_text(s, {"type": "set_config"}, cfg, prompts)
        assert s.system_prompt is None
        assert prompts.is_default


@pytest.mark.asyncio
class TestDispatchTextQuery:
    async def test_text_query_when_idle_spawns_generation(self):
        s = _make_session()
        await dispatch_text(
            s, {"type": "text_query", "text": "hello"}, cfg, PromptStore(),
        )
        # Transcript echoed back so the client renders the user turn.
        assert s.send.await_count == 1
        echoed = s.send.call_args[0][0]
        assert echoed.text == "hello"
        # Generation task spawned.
        s.spawn.assert_called_once()

    async def test_text_query_when_busy_ignored(self):
        from session import ServerState
        s = _make_session()
        s.state = ServerState.RESPONDING
        await dispatch_text(
            s, {"type": "text_query", "text": "hello"}, cfg, PromptStore(),
        )
        s.send.assert_not_called()
        s.spawn.assert_not_called()

    async def test_text_query_empty_text_ignored(self):
        s = _make_session()
        await dispatch_text(s, {"type": "text_query", "text": "   "}, cfg, PromptStore())
        s.send.assert_not_called()
        s.spawn.assert_not_called()


@pytest.mark.asyncio
class TestDispatchEndRecording:
    async def test_end_recording_with_audio_spawns_processing(self):
        s = _make_session()
        s.audio_buffer.add(b"\x00\x00" * 16000)  # 1s of silence
        await dispatch_text(s, {"type": "end_recording"}, cfg, PromptStore())
        s.spawn.assert_called_once()

    async def test_end_recording_no_audio_no_spawn(self):
        s = _make_session()
        await dispatch_text(s, {"type": "end_recording"}, cfg, PromptStore())
        s.spawn.assert_not_called()

    async def test_end_recording_history_field_warns_once(self):
        s = _make_session()
        await dispatch_text(
            s,
            {"type": "end_recording", "history": [{"role": "user", "content": "x"}]},
            cfg,
            PromptStore(),
        )
        assert s._client_history_warned is True


@pytest.mark.asyncio
class TestDispatchTtsRequest:
    async def test_tts_request_with_text_spawns(self):
        s = _make_session()
        await dispatch_text(
            s, {"type": "tts_request", "text": "say this"}, cfg, PromptStore(),
        )
        s.spawn.assert_called_once()

    async def test_tts_request_empty_text_ignored(self):
        s = _make_session()
        await dispatch_text(s, {"type": "tts_request", "text": ""}, cfg, PromptStore())
        s.spawn.assert_not_called()
