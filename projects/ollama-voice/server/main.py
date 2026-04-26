"""Entrypoint for the ollama-voice server.

The actual app lives in `app.py`. This module exists so `python main.py`
keeps working as the canonical launch command, and so test code can keep
importing common symbols from `main`.
"""

from app import app, cfg  # noqa: F401  re-exported for tests
from audio import VAD_CHUNK_SIZE, VAD_SPLIT_SIZE  # noqa: F401  re-exported for tests
from pipeline import AUDIO_CHUNK_SIZE  # noqa: F401  re-exported for tests
from session import ServerState  # noqa: F401  re-exported for tests


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=cfg.server.host, port=cfg.server.port)
