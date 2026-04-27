"""Pydantic models for WebSocket messages."""

from typing import Annotated, Literal, Union
from pydantic import BaseModel, ConfigDict, Field, TypeAdapter, ValidationError


# ── Incoming messages ────────────────────────────────────────────────────
# All incoming messages use Literal `type` so a discriminated union can
# parse them in one shot. Unknown fields are ignored so the wire format
# stays forward-compatible.


class _Incoming(BaseModel):
    model_config = ConfigDict(extra="ignore")


class AuthMessage(_Incoming):
    type: Literal["auth"] = "auth"
    token: str
    connection_id: str | None = None
    agent: str | None = None
    mode: Literal["ptt", "hands_free"] = "ptt"
    system_prompt: str | None = None  # None = use server default


class InterruptMessage(_Incoming):
    type: Literal["interrupt"] = "interrupt"
    request_id: str = ""


class EndRecordingMessage(_Incoming):
    type: Literal["end_recording"] = "end_recording"
    history: list | None = None  # deprecated — server owns history


class TtsRequestMessage(_Incoming):
    type: Literal["tts_request"] = "tts_request"
    text: str = ""


class TextQueryMessage(_Incoming):
    type: Literal["text_query"] = "text_query"
    text: str = ""
    history: list | None = None  # deprecated — server owns history


class PingMessage(_Incoming):
    type: Literal["ping"] = "ping"


class GetConfigMessage(_Incoming):
    type: Literal["get_config"] = "get_config"


class SetConfigMessage(_Incoming):
    type: Literal["set_config"] = "set_config"
    system_prompt: str | None = None  # None = reset to default


IncomingTextMessage = Annotated[
    Union[
        InterruptMessage,
        EndRecordingMessage,
        TtsRequestMessage,
        TextQueryMessage,
        PingMessage,
        GetConfigMessage,
        SetConfigMessage,
    ],
    Field(discriminator="type"),
]

_text_adapter: TypeAdapter[IncomingTextMessage] = TypeAdapter(IncomingTextMessage)


def parse_text_message(data: dict) -> IncomingTextMessage:
    """Parse an incoming text-frame dict into a typed message.

    Raises pydantic.ValidationError on unknown type or missing required fields.
    """
    return _text_adapter.validate_python(data)


def parse_auth_message(data: dict) -> AuthMessage:
    """Parse an incoming auth-handshake dict into an AuthMessage.

    Raises pydantic.ValidationError on missing token / wrong shape.
    """
    return AuthMessage.model_validate(data)


# ── Outgoing messages ────────────────────────────────────────────────────


class AuthOkMessage(BaseModel):
    type: str = "auth_ok"


class AuthFailedMessage(BaseModel):
    type: str = "auth_failed"
    reason: str = "Invalid token"


class TranscriptMessage(BaseModel):
    type: str = "transcript"
    text: str


class ResponseStartMessage(BaseModel):
    type: str = "response_start"
    text: str = ""


class ResponseDeltaMessage(BaseModel):
    type: str = "response_delta"
    text: str  # incremental token chunk


class AudioStartMessage(BaseModel):
    type: str = "audio_start"
    duration_ms: int = 0


class AudioEndMessage(BaseModel):
    type: str = "audio_end"


class InterruptAckMessage(BaseModel):
    type: str = "interrupt_ack"
    request_id: str = ""


class ErrorMessage(BaseModel):
    type: str = "error"
    message: str


class ConnectionReplacedMessage(BaseModel):
    type: str = "connection_replaced"


class ResponseEndMessage(BaseModel):
    type: str = "response_end"
    text: str = ""  # full response text — client uses this for history


class TtsOnlyStartMessage(BaseModel):
    type: str = "tts_only_start"


class TtsOnlyEndMessage(BaseModel):
    type: str = "tts_only_end"


class ListeningStartMessage(BaseModel):
    type: str = "listening_start"


class ListeningEndMessage(BaseModel):
    type: str = "listening_end"


class ConfigMessage(BaseModel):
    type: str = "config"
    system_prompt: str  # current effective system prompt
    is_default: bool  # True if using the server default


class ConfigSavedMessage(BaseModel):
    type: str = "config_saved"
    system_prompt: str  # the saved prompt


class ConfigResetMessage(BaseModel):
    type: str = "config_reset"
    system_prompt: str  # the default prompt now active