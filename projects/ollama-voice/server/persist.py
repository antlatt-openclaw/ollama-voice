"""Server-side persistence for client settings (system prompt, etc.)."""

import json
import logging
from pathlib import Path

log = logging.getLogger("persist")

DATA_DIR = Path(__file__).parent / "data"
SETTINGS_FILE = DATA_DIR / "settings.json"


def _ensure_dir():
    DATA_DIR.mkdir(parents=True, exist_ok=True)


def load_system_prompt() -> str | None:
    """Load saved system prompt, or None if no custom prompt is saved."""
    try:
        if SETTINGS_FILE.exists():
            data = json.loads(SETTINGS_FILE.read_text())
            prompt = data.get("system_prompt")
            if prompt is not None:
                log.info("Loaded saved system prompt (%d chars)", len(prompt))
                return prompt
    except Exception as e:
        log.error("Failed to load settings: %s", e)
    return None


def save_system_prompt(prompt: str):
    """Save a custom system prompt to disk."""
    _ensure_dir()
    try:
        if SETTINGS_FILE.exists():
            data = json.loads(SETTINGS_FILE.read_text())
        else:
            data = {}
        data["system_prompt"] = prompt
        SETTINGS_FILE.write_text(json.dumps(data, indent=2))
        log.info("Saved system prompt (%d chars)", len(prompt))
    except Exception as e:
        log.error("Failed to save settings: %s", e)
        raise


def reset_system_prompt():
    """Delete the saved custom system prompt (revert to default)."""
    try:
        if SETTINGS_FILE.exists():
            data = json.loads(SETTINGS_FILE.read_text())
            if "system_prompt" in data:
                del data["system_prompt"]
                SETTINGS_FILE.write_text(json.dumps(data, indent=2))
                log.info("Reset system prompt to default")
            else:
                log.debug("No custom system prompt to reset")
    except Exception as e:
        log.error("Failed to reset settings: %s", e)
        raise