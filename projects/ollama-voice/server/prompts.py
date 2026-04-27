"""System-prompt store: server default + persisted override.

The server-default is loaded by ``load_default_prompt()`` and resolves in
this order:

1. ``DEFAULT_SYSTEM_PROMPT`` env var — used verbatim if set and non-empty.
2. ``DEFAULT_SYSTEM_PROMPT_FILE`` env var — text file path; loaded if readable.
3. ``BUILTIN_DEFAULT_PROMPT`` — a generic fallback compiled into the binary.

A persisted override (set via the WebSocket ``set_config`` message and
stored in ``data/settings.json``) takes precedence over all of the above.
"""

import logging
import os
from pathlib import Path

from persist import load_system_prompt, reset_system_prompt, save_system_prompt

log = logging.getLogger("server")


# Generic fallback. Operators ship their own persona via DEFAULT_SYSTEM_PROMPT(_FILE).
BUILTIN_DEFAULT_PROMPT = (
    "You are a helpful voice assistant. You are speaking aloud over voice, not writing text — "
    "keep responses short (1-3 sentences) and conversational. Use natural contractions and "
    "flowing sentences. Never use markdown, bullet points, or code blocks; you are talking, "
    "not typing."
)


def load_default_prompt() -> str:
    """Resolve the server-default system prompt from env vars, with a built-in fallback."""
    direct = os.environ.get("DEFAULT_SYSTEM_PROMPT", "").strip()
    if direct:
        log.info("Using DEFAULT_SYSTEM_PROMPT from env (%d chars)", len(direct))
        return direct

    path = os.environ.get("DEFAULT_SYSTEM_PROMPT_FILE", "").strip()
    if path:
        try:
            text = Path(path).read_text(encoding="utf-8").strip()
            if text:
                log.info("Loaded default prompt from %s (%d chars)", path, len(text))
                return text
            log.warning("DEFAULT_SYSTEM_PROMPT_FILE=%s is empty; using built-in fallback", path)
        except Exception as e:
            log.warning("Could not read DEFAULT_SYSTEM_PROMPT_FILE=%s (%s); using built-in fallback", path, e)

    return BUILTIN_DEFAULT_PROMPT


class PromptStore:
    """Server-default + persisted system prompt. Per-session overrides live on Session."""

    def __init__(self, default: str | None = None):
        self._default = default if default is not None else BUILTIN_DEFAULT_PROMPT
        self._persisted: str | None = None

    def load(self):
        self._persisted = load_system_prompt()

    @property
    def is_default(self) -> bool:
        return self._persisted is None

    @property
    def effective(self) -> str:
        return self._persisted or self._default

    @property
    def default(self) -> str:
        return self._default

    def set(self, prompt: str):
        save_system_prompt(prompt)
        self._persisted = prompt

    def reset(self):
        reset_system_prompt()
        self._persisted = None

    def resolve(self, override: str | None) -> str:
        """Effective prompt for a session, honoring its per-session override."""
        return override or self.effective
