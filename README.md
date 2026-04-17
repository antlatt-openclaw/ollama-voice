# Ollama Voice

Uncensored voice assistant Android app with Python FastAPI server backend.

## Features

- **Push-to-talk and hands-free modes** for voice interaction
- **Smart turn detection** using Silero VAD + SmartTurn model
- **Local Ollama integration** for uncensored AI responses
- **Multiple TTS backends** with automatic fallback (VibeVoice → Kokoro → Qwen3)
- **Groq Whisper** for fast speech-to-text
- **Configurable system prompts** per session
- **Conversation history** with SQLite persistence

## Architecture

```
┌─────────────────┐     WebSocket      ┌──────────────────┐
│  Android App    │◄──────────────────►│  FastAPI Server   │
│  (Flutter/Dart) │   wss://domain/ws  │  (Python)         │
└─────────────────┘                    └──────────────────┘
                                                │
                       ┌────────────────────────┼────────────────────────┐
                       │                        │                        │
                       ▼                        ▼                        ▼
               ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
               │   Ollama    │         │ Groq Whisper│         │  VibeVoice  │
               │  (LLM API)  │         │   (STT)     │         │   (TTS)     │
               └─────────────┘         └─────────────┘         └─────────────┘
```

## Server Setup

### Requirements

- Python 3.11+
- Ollama running locally or remotely
- Groq API key (for Whisper STT)
- Vibevoice server (or Kokoro fallback)

### Installation

```bash
cd server
pip install -r requirements.txt
```

### Configuration

Set environment variables:

```bash
export AUTH_TOKEN="your-secure-token"
export OLLAMA_URL="http://localhost:11434"
export VIBEVOICE_URL="http://localhost:7860"
export SERVER_PORT="8001"
```

### Running

```bash
python main.py
```

Server runs on `http://0.0.0.0:8001` by default.

## Android App

### Building

```bash
cd client
flutter build apk --release
```

APK output: `build/app/outputs/flutter-apk/app-release.apk`

### Configuration

In app settings:
- Server URL (e.g., `wss://ollama-voice.antlatt.com/ws`)
- Auth token
- System prompt (optional override)

## License

MIT