"""Server-side persistence for client settings (system prompt, etc.)."""

import json
import logging
import os
import tempfile
from pathlib import Path

log = logging.getLogger("persist")

DATA_DIR = Path(__file__).parent / "data"
SETTINGS_FILE = DATA_DIR / "settings.json"

# Maximum size (bytes) for the settings JSON file.
MAX_SETTINGS_FILE_SIZE = 1048576


def _ensure_dir():
    DATA_DIR.mkdir(parents=True, exist_ok=True)


def _safe_load(path: Path) -> dict:
    """Load JSON from *path* with a max-size guard."""
    if not path.exists():
        return {}
    size = path.stat().st_size
    if size > MAX_SETTINGS_FILE_SIZE:
        raise ValueError(f"Settings file too large ({size} bytes)")
    return json.loads(path.read_text())


def _atomic_write_json(path: Path, data: dict):
    """Write JSON atomically: tmpfile in same dir, then os.replace."""
    _ensure_dir()
    tmp = tempfile.NamedTemporaryFile(
        mode="w", dir=path.parent, delete=False, suffix=".tmp"
    )
    try:
        tmp.write(json.dumps(data, indent=2))
        tmp.close()
        os.replace(tmp.name, path)
    except Exception:
        tmp.close()
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        raise


def load_system_prompt() -> str | None:
    """Load saved system prompt, or None if no custom prompt is saved."""
    try:
        data = _safe_load(SETTINGS_FILE)
        prompt = data.get("system_prompt")
        if prompt is not None:
            log.info("Loaded saved system prompt (%d chars)", len(prompt))
            return prompt
    except Exception as e:
        log.error("Failed to load settings: %s", e)
    return None


def save_system_prompt(prompt: str):
    """Save a custom system prompt to disk atomically."""
    try:
        data = _safe_load(SETTINGS_FILE)
        data["system_prompt"] = prompt
        _atomic_write_json(SETTINGS_FILE, data)
        log.info("Saved system prompt (%d chars)", len(prompt))
    except Exception as e:
        log.error("Failed to save settings: %s", e)
        raise


def reset_system_prompt():
    """Delete the saved custom system prompt (revert to default)."""
    try:
        data = _safe_load(SETTINGS_FILE)
        if "system_prompt" not in data:
            log.debug("No custom system prompt to reset")
            return
        del data["system_prompt"]
        _atomic_write_json(SETTINGS_FILE, data)
        log.info("Reset system prompt to default")
    except Exception as e:
        log.error("Failed to reset settings: %s", e)
        raise
