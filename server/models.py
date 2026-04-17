"""Pydantic models for WebSocket messages."""

from typing import Literal
from pydantic import BaseModel


class AuthMessage(BaseModel):
    type: str = "auth"
    token: str
    connection_id: str | None = None
    agent: str | None = None
    mode: Literal["ptt", "hands_free"] = "ptt"
    system_prompt: str | None = None  # None = use server default


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