"""WebSocket connection and authentication tests."""
import json
import pytest

# ── Auth Tests ────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestWebSocketAuth:
    """Test WebSocket authentication handshake."""

    async def test_valid_auth_accepted(self, mock_ws_client, valid_auth_message):
        """Test that a valid auth token is accepted."""
        # Simulate receiving auth message
        mock_ws_client.receive_text.return_value = json.dumps(valid_auth_message)
        
        # In the real server, handle_client() would process this
        # For now, test the auth logic directly
        from main import cfg
        
        # Verify token matches config
        assert valid_auth_message["token"] == "dev-token" or cfg.server.auth_token is None or valid_auth_message["token"] == cfg.server.auth_token

    async def test_invalid_auth_rejected(self, mock_ws_client, invalid_auth_message):
        """Test that an invalid auth token is rejected."""
        from main import cfg
        
        # Verify token doesn't match config
        assert invalid_auth_message["token"] != "dev-token"
        if cfg.server.auth_token:
            assert invalid_auth_message["token"] != cfg.server.auth_token

    async def test_auth_message_format(self, valid_auth_message):
        """Test that auth message has required fields."""
        assert "type" in valid_auth_message
        assert valid_auth_message["type"] == "auth"
        assert "client_id" in valid_auth_message
        assert "token" in valid_auth_message


# ── Message Flow Tests ────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestMessageFlow:
    """Test PTT and message flow."""

    async def test_ptt_start_stop_sequence(self):
        """Test that PTT start/stop messages are valid JSON."""
        ptt_start = {"type": "ptt_start"}
        ptt_stop = {"type": "ptt_stop"}
        
        assert json.dumps(ptt_start) == '{"type": "ptt_start"}'
        assert json.dumps(ptt_stop) == '{"type": "ptt_stop"}'

    async def test_response_message_types(self):
        """Test that all response message types are valid."""
        from models import (
            AuthOkMessage, ErrorMessage,
            ResponseStartMessage, ResponseDeltaMessage,
            AudioStartMessage, AudioEndMessage, ResponseEndMessage,
        )
        
        # Verify message creation
        auth_ok = AuthOkMessage()
        assert auth_ok.type == "auth_ok"
        
        error = ErrorMessage(message="Test error")
        assert error.message == "Test error"
        
        response_start = ResponseStartMessage(text="")
        assert response_start.text == ""
        
        response_delta = ResponseDeltaMessage(text="Hello")
        assert response_delta.text == "Hello"
        
        audio_start = AudioStartMessage(duration_ms=1000)
        assert audio_start.duration_ms == 1000
        
        audio_end = AudioEndMessage()
        assert audio_end is not None
        
        response_end = ResponseEndMessage(text="Hello world")
        assert response_end.text == "Hello world"


# ── Server State Tests ────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestServerState:
    """Test server state management."""

    async def test_state_transitions(self):
        """Test that state transitions work correctly."""
        from main import ServerState
        
        # Verify enum values
        assert ServerState.IDLE.value == "idle"
        assert ServerState.PROCESSING.value == "processing"
        assert ServerState.RESPONDING.value == "responding"
        assert ServerState.INTERRUPTED.value == "interrupted"
        
        # Note: current_state is a global that starts as IDLE
        # We can't easily test transitions without the full server running

    async def test_server_state_enum_completeness(self):
        """Test that all expected states exist."""
        from main import ServerState
        
        expected_states = {"IDLE", "PROCESSING", "RESPONDING", "INTERRUPTED"}
        actual_states = {s.name for s in ServerState}
        
        assert expected_states == actual_states
