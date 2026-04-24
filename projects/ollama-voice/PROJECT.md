# Ollama Voice Project

**Version:** 1.0.0+4

## Version
**1.0.0** — First stable release — real-time voice pipeline complete.

## Overview
Real-time voice chat system: FastAPI WebSocket server + Flutter client app.
Full pipeline: audio in → speech-to-text → LLM response → text-to-speech → audio out.

## Architecture

### Server (`server/`)
- **Framework**: FastAPI + WebSocket
- **Port**: 8001 (configurable in `.env`)
- **STT**: Groq Whisper (whisper-large-v3-turbo)
- **LLM**: Local Ollama (`huihui_ai/gemma-4-abliterated:e4b`)
- **TTS**: Three-tier fallback
  1. VibeVoice (primary, custom "Beatrice" voice) @ 192.168.1.210:7860
  2. Kokoro (local, lightweight)
  3. Qwen3 (local, final fallback)
- **VAD**: Silero VAD with pipecat smart-turn-v3.2
- **Auth**: Token-based (set in `.env`)

### Client (`client/`)
- **Framework**: Flutter
- **Platforms**: Android, iOS (future: desktop)
- **Connection**: WebSocket to server
- **Modes**: Push-to-talk (PTT) + Hands-free
- **State Management**: Provider pattern

## Current State

### Server
- ✅ Full voice pipeline working (STT → LLM → TTS)
- ✅ Hands-free mode with SmartTurn detection
- ✅ Configurable system prompt (persistent)
- ✅ Auth token validation
- ✅ Graceful shutdown
- ✅ TTS concurrency limiting (max 3 simultaneous)
- ✅ Retry logic for STT (Groq rate limits) and TTS
- ✅ Config validation on startup
- ✅ Test infrastructure (pytest, 21 tests passing)

### Client
- ✅ Basic UI with connection screen
- ✅ WebSocket connection with auth
- ✅ PTT mode (hold to record, release to send)
- 🔄 Hands-free mode UI (needs polish)
- 🔄 Connection state visualization (in progress)
- ❌ Voice recording visualization (waveform)
- ❌ Settings/config screen
- ❌ System prompt editing
- ❌ Offline/cache handling

## Active Work

| Agent | Task | Status | Blocked On |
|-------|------|--------|------------|
| maxx | Client voice recording + WebSocket stability | ⏸️ On Hold | maxx unavailable |
| beatrice | Client UI/UX design specs | 🔄 Ready to Start | — |
| samantha | Server Docker deployment | 📋 Backlog | — |
| sean | Project coordination + task tracking | 🔄 Active | — |

## Project Files

### Server
- `main.py` — FastAPI app, WebSocket handler, state machine
- `config.py` — Settings loader + validation
- `audio.py` — VAD + SmartTurn detector
- `stt.py` — Groq Whisper transcription
- `ollama.py` — LLM token streaming
- `tts.py` — TTS synthesis with fallback chain
- `models.py` — Pydantic message schemas
- `persist.py` — Settings persistence (data/settings.json)
- `.env` — Secrets (auth token, Groq key, Ollama URL, VibeVoice URL)
- `requirements.txt` — Pinned dependencies
- `data/settings.json` — Persisted system prompt

### Client
- `lib/main.dart` — Entry point
- `lib/app.dart` — App shell + routing
- `lib/screens/main_screen.dart` — Main voice chat UI
- `lib/screens/onboarding_screen.dart` — First-run setup
- `lib/providers/` — State management (app, connection, conversation)
- `lib/services/` — Business logic (audio, network, config, storage)
- `lib/models/` — Data models
- `lib/widgets/` — Reusable UI components

## Key Decisions

1. **Single-connection model**: Server allows only one active WebSocket at a time. New connections replace old ones.
2. **Full-response TTS**: Instead of per-sentence TTS (sounded disjointed), the server collects the full LLM response and synthesizes it as one unit for natural prosody.
3. **SmartTurn for hands-free**: Uses pipecat's turn-detection model to know when the user has finished speaking, rather than fixed silence thresholds.
4. **System prompt persistence**: Custom prompts survive server restarts via JSON file.

## Blockers
- None currently

## Notes
- Server runs as systemd service (`vibevoice-tts-proxy.service` is actually the TTS proxy; the voice server itself needs its own service unit)
- VibeVoice Gradio at `192.168.1.210:7860` → proxy at `127.0.0.1:7861`
- ONNX thread affinity warnings in logs are harmless (container environment, no GPU pinning)

## CHANGELOG
See [CHANGELOG.md](./CHANGELOG.md) for detailed history of fixes and improvements.
