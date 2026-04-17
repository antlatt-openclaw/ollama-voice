# Ollama Voice — Session Context

Read this file at the start of any new session.

---

## What This Project Is

A standalone voice assistant app for Android that connects directly to a local Ollama instance.

**Pipeline:** Mic → Groq Whisper STT → Ollama LLM → VibeVoice TTS → Speaker

**Key feature:** Uses uncensored models via Ollama — no cloud gateway, no auth for LLM, full local control.

---

## Project Structure

```
ollama-voice/
├── SESSION_CONTEXT.md       # This file
├── server/                  # Python FastAPI backend
│   ├── main.py              # WebSocket server (auth, PTT, hands-free, TTS-only)
│   ├── ollama.py            # Ollama SSE streaming client
│   ├── config.py            # Config from .env
│   ├── models.py            # Pydantic WS message models
│   ├── audio.py             # Silero VAD + SmartTurn + WAV utils
│   ├── stt.py               # Groq Whisper transcription
│   ├── tts.py               # VibeVoice → Kokoro → Qwen3 fallback chain
│   ├── requirements.txt     # Python deps
│   └── .env                 # API keys + config
└── client/                  # Flutter Android app
    ├── lib/
    │   ├── main.dart
    │   ├── app.dart
    │   ├── models/
    │   ├── providers/       # app_state, connection_state, conversation_state
    │   ├── screens/         # main_screen, onboarding_screen
    │   ├── services/        # audio, config, network, storage
    │   ├── theme/
    │   └── widgets/
    └── android/             # Android build config
```

---

## Server

**Port:** 8001
**Domain:** `ollama-voice.antlatt.com` (Nginx proxy with SSL)

### Endpoints

- `GET /health` — Health check, returns Ollama connectivity status
- `GET /status` — Server config info
- `WS /ws` — WebSocket connection for voice streaming

### Message Types

- `auth` — Client sends auth token
- `ptt_start` / `ptt_end` — Push-to-talk mode
- `hands_free_start` / `hands_free_end` — Hands-free (VAD) mode
- `text_query` — Send text instead of voice
- `interrupt` — Stop current TTS playback
- `tts_replay` — Replay last response as audio

### How to Start

```bash
cd /root/.openclaw/antlatt-workspace/projects/ollama-voice/server
nohup python3 main.py >> /tmp/ollama-voice-server.log 2>&1 &
```

### Health Check

```bash
curl http://localhost:8001/health
```

---

## Client (Flutter)

**App ID:** `com.openclaw.ollamavoice`
**Platform:** Android only (no iOS)

### Key Services

- `RecorderService` — flutter_sound PCM 16kHz streaming
- `PlayerService` — just_audio with WAV wrapper for PCM playback
- `WebSocketService` — Auth, keepalive, message handling
- `AudioModeService` — Android AudioManager for BT routing
- `ConfigService` — SharedPreferences for settings
- `ConversationState` — SQLite persistence for chat history

### Settings Sheet (in main_screen.dart)

Accessible via gear icon in the app bar:

| Section | Settings |
|---------|----------|
| **CHAT** | Font size slider, clear conversation, export conversation |
| **INPUT** | Hands-free mode, tap-to-toggle, barge-in toggle |
| **OUTPUT** | Split response into sentences (lower latency) |
| **AGENT** | Agent selection (default only for ollama-voice) |
| **APPEARANCE** | Theme (dark/light/auto) |
| **POWER** | Keep screen on |
| **DEVELOPER** | Latency overlay (STT/LLM/TTS timing) |
| **CONNECTION** | Server URL, auth token (both editable) |

### How to Build APK

```bash
cd /root/.openclaw/antlatt-workspace/projects/ollama-voice/client
ANDROID_HOME=/opt/android-sdk flutter build apk --release
```

---

## Current Model

`huihui_ai/gemma-4-abliterated:e4b` — uncensored Gemma 4 via Ollama

---

## .env (server)

```
GROQ_API_KEY=<groq api key for Whisper STT>
AUTH_TOKEN=<shared secret for client auth>
# Optional overrides:
# OLLAMA_URL=http://localhost:11434/v1/chat/completions
# OLLAMA_MODEL=huihui_ai/gemma-4-abliterated:e4b
```

---

## Known Issues

1. **VibeVoice latency** — Uses podcast generation API (fn_index=3), not optimized for real-time single-sentence TTS
2. **Barge-in disabled** — Hardware AEC over-suppresses user voice during playback
3. **No server-side persistence** — Conversation history lost on disconnect (client has SQLite)
4. **No iOS client** — Android only

---

## Future Work

- [ ] Improve TTS latency (use streaming TTS endpoint instead of podcast API)
- [ ] Add software AEC for barge-in support
- [ ] Make system prompt configurable from app
- [ ] Add text input UI
- [ ] iOS support