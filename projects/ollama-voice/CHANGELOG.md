# Changelog

## 2026-04-21 — Code Review & Bug Fixes

### Context
Full code review of the ollama-voice WebSocket server. All issues found were fixed across 3 commits on the `workflow-fix` branch.

### Critical Fixes (Commit 1: `b5e2a1b6`)

1. **TTS Concurrency Limit** (`main.py`)
   - Added `MAX_CONCURRENT_TTS = 3` semaphore to prevent overwhelming VibeVoice with 50+ simultaneous requests during LLM streaming
   - New `_synthesize_with_limit()` wraps `synthesize()` with `asyncio.Semaphore`

2. **TTS Fallback Exception Handling** (`tts.py`)
   - Each TTS backend (`_vibevoice`, `_kokoro`, `_qwen3`) now wrapped in its own `try/except`
   - Previously, an exception in `_vibevoice()` would propagate up and skip Kokoro/Qwen3 fallbacks

3. **SmartTurn Model Download Timeout** (`audio.py`)
   - Added `timeout=30` to `hf_hub_download()` call to prevent indefinite hang on first startup

### High/Medium Priority Fixes (Commit 2: `694fb7f1`)

4. **AudioStartMessage duration** (`main.py`)
   - Changed from first-sentence-only duration to `duration_ms=0` (streaming, duration unknown)
   - Clients should treat `duration_ms=0` as "streaming, total unknown"

5. **Abbreviation-Aware Sentence Splitting** (`main.py`)
   - Replaced regex-based `SENTENCE_RE` with word-based parser
   - Added `ABBREVIATIONS` set (Mr, Dr, e.g., i.e., etc., months, etc.) to avoid false splits
   - Removed unused `import re`

6. **STT Retries + Language Parameter** (`stt.py`)
   - Added `MAX_RETRIES = 2` with exponential backoff for Groq 429 (rate limit) errors
   - Added `language` parameter to `transcribe()` (default `"en"`) for multilingual support

7. **TTS VibeVoice Retries** (`tts.py`)
   - Added retry loop with exponential backoff for HTTP 429/502/503/504 errors
   - `MAX_RETRIES = 2` (3 total attempts)

8. **Per-Chunk Ollama SSE Timeout** (`ollama.py`)
   - Added `PER_CHUNK_TIMEOUT = 30.0` seconds
   - Uses `asyncio.wait_for()` on each SSE line read to detect stalled generation
   - Prevents infinite hang if Ollama stops sending tokens

### Low Priority Fixes (Commit 3: `a8085bf9`)

9. **Dead Code Removal** (`audio.py`)
   - Removed `add_speech_chunk()` method — never called anywhere

10. **VAD Auto-Padding** (`audio.py`)
    - `get_speech_prob()` now pads short chunks with last sample value (instead of returning 0.0)
    - Long chunks are truncated with a warning (instead of silently dropped)
    - Prevents audio loss when clients send slightly mismatched chunk sizes

11. **Config Validation** (`config.py`)
    - Added validation at `load_config()` time:
      - Port: 1–65535
      - TTS speed: > 0
      - TTS sample rate: 8000–192000
      - Smart turn threshold: 0.0–1.0
      - Auth timeout: > 0
      - Ollama timeout: > 0

12. **Version Pinning** (`requirements.txt`)
    - All deps now have upper bounds (e.g., `torch>=2.0.0,<3.0.0`)
    - Prevents accidental major version upgrades

### Files Modified
- `server/main.py` — TTS concurrency, sentence splitting, AudioStart duration
- `server/tts.py` — fallback exception handling, VibeVoice retries
- `server/stt.py` — retries, language parameter
- `server/ollama.py` — per-chunk SSE timeout
- `server/audio.py` — SmartTurn timeout, dead code removal, VAD auto-padding
- `server/config.py` — validation
- `server/requirements.txt` — version pinning

### Server Status
- Server running on `http://0.0.0.0:8001` (PID 116655 as of 11:37 EDT)
- ONNX thread affinity warnings are harmless (container environment, no GPU)
- All models loaded: VAD + SmartTurn (pipecat smart-turn-v3.2)

### Remaining Known Issues
- **No unit tests** — all testing was import-based (`python3 -c "import main; ..."`)
- **VibeVoice latency** — the Gradio queue API can be slow; consider streaming TTS in future
- **No graceful shutdown** — WebSocket connections not drained on server stop
- **HF_TOKEN warning** — set `HF_TOKEN` env var for faster model downloads on fresh starts