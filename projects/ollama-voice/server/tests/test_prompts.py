"""Tests for the default-prompt loader and PromptStore precedence."""
import pytest

from prompts import BUILTIN_DEFAULT_PROMPT, PromptStore, load_default_prompt


class TestLoadDefaultPrompt:
    def test_returns_builtin_when_unset(self, monkeypatch):
        monkeypatch.delenv("DEFAULT_SYSTEM_PROMPT", raising=False)
        monkeypatch.delenv("DEFAULT_SYSTEM_PROMPT_FILE", raising=False)
        assert load_default_prompt() == BUILTIN_DEFAULT_PROMPT

    def test_inline_env_var_wins(self, monkeypatch):
        monkeypatch.setenv("DEFAULT_SYSTEM_PROMPT", "be a pirate")
        monkeypatch.delenv("DEFAULT_SYSTEM_PROMPT_FILE", raising=False)
        assert load_default_prompt() == "be a pirate"

    def test_blank_inline_falls_through_to_builtin(self, monkeypatch):
        monkeypatch.setenv("DEFAULT_SYSTEM_PROMPT", "   ")
        monkeypatch.delenv("DEFAULT_SYSTEM_PROMPT_FILE", raising=False)
        assert load_default_prompt() == BUILTIN_DEFAULT_PROMPT

    def test_file_env_var(self, tmp_path, monkeypatch):
        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("from a file", encoding="utf-8")
        monkeypatch.delenv("DEFAULT_SYSTEM_PROMPT", raising=False)
        monkeypatch.setenv("DEFAULT_SYSTEM_PROMPT_FILE", str(prompt_file))
        assert load_default_prompt() == "from a file"

    def test_inline_takes_precedence_over_file(self, tmp_path, monkeypatch):
        prompt_file = tmp_path / "prompt.txt"
        prompt_file.write_text("from a file", encoding="utf-8")
        monkeypatch.setenv("DEFAULT_SYSTEM_PROMPT", "from inline")
        monkeypatch.setenv("DEFAULT_SYSTEM_PROMPT_FILE", str(prompt_file))
        assert load_default_prompt() == "from inline"

    def test_missing_file_falls_through_to_builtin(self, tmp_path, monkeypatch):
        monkeypatch.delenv("DEFAULT_SYSTEM_PROMPT", raising=False)
        monkeypatch.setenv("DEFAULT_SYSTEM_PROMPT_FILE", str(tmp_path / "nonexistent.txt"))
        assert load_default_prompt() == BUILTIN_DEFAULT_PROMPT

    def test_empty_file_falls_through_to_builtin(self, tmp_path, monkeypatch):
        prompt_file = tmp_path / "empty.txt"
        prompt_file.write_text("   \n\n  ", encoding="utf-8")
        monkeypatch.delenv("DEFAULT_SYSTEM_PROMPT", raising=False)
        monkeypatch.setenv("DEFAULT_SYSTEM_PROMPT_FILE", str(prompt_file))
        assert load_default_prompt() == BUILTIN_DEFAULT_PROMPT


class TestPromptStorePrecedence:
    def test_default_is_used_when_no_override_persisted(self):
        store = PromptStore(default="DEFAULT")
        assert store.effective == "DEFAULT"
        assert store.is_default

    def test_persisted_override_wins_over_default(self):
        store = PromptStore(default="DEFAULT")
        store._persisted = "PERSISTED"
        assert store.effective == "PERSISTED"
        assert not store.is_default

    def test_session_override_wins_over_persisted(self):
        store = PromptStore(default="DEFAULT")
        store._persisted = "PERSISTED"
        assert store.resolve(override="SESSION") == "SESSION"

    def test_resolve_falls_through_to_effective_when_no_override(self):
        store = PromptStore(default="DEFAULT")
        store._persisted = "PERSISTED"
        assert store.resolve(override=None) == "PERSISTED"
        assert store.resolve(override="") == "PERSISTED"

    def test_constructor_default_none_uses_builtin(self):
        store = PromptStore(default=None)
        assert store.default == BUILTIN_DEFAULT_PROMPT

    def test_default_property_does_not_change_with_persistence(self):
        store = PromptStore(default="DEFAULT")
        store._persisted = "PERSISTED"
        # `default` is the cold-start fallback, not the current effective prompt.
        assert store.default == "DEFAULT"
