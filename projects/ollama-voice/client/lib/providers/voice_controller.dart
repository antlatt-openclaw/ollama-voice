import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/websocket_event.dart';
import '../services/audio/audio_coordinator.dart';
import '../services/audio/audio_mode_service.dart';
import '../services/audio/bluetooth_service.dart';
import '../services/audio/player_service.dart';
import '../services/config/config_service.dart';
import '../services/notification_service.dart';
import 'app_state.dart';
import 'connection_state.dart' show VoiceConnectionState;
import 'conversation_state.dart';

/// Owns the per-session orchestration that used to live in MainScreen:
/// websocket event dispatch, PTT/hands-free state machine, wake-word loop,
/// proximity sensor, Bluetooth monitoring, latency tracking. The widget
/// renders state read from this controller; user actions are forwarded
/// here via the public methods.
class VoiceController extends ChangeNotifier with WidgetsBindingObserver {
  // ── Dependencies (injected once via Provider) ───────────────────────────
  final AppState _appState;
  final VoiceConnectionState _connection;
  final ConversationState _conversation;
  final AudioCoordinator _audio;
  final PlayerService _player;
  final BluetoothService _bluetooth;
  final ConfigService _config;

  // ── Subscriptions ────────────────────────────────────────────────────────
  StreamSubscription? _wsEventSub;
  StreamSubscription? _wsAudioSub;
  StreamSubscription? _recorderSub;
  StreamSubscription? _bargeInSub;
  StreamSubscription? _vadSub;
  StreamSubscription? _wakeWordSub;
  StreamSubscription? _playbackCompleteSub;
  StreamSubscription? _proximitySub;
  StreamSubscription? _bluetoothSub;

  /// Serializes async event handling so events are never processed concurrently.
  Future<void> _eventChain = Future.value();

  // ── Display state (read by MainScreen) ──────────────────────────────────
  String _currentTranscript = '';
  String _currentResponse = '';
  bool _isResponding = false;
  bool _isProcessing = false;
  bool _responseWasInterrupted = false;

  String get currentTranscript => _currentTranscript;
  String get currentResponse => _currentResponse;
  bool get isResponding => _isResponding;
  bool get isProcessing => _isProcessing;

  // ── Internal phase flags ────────────────────────────────────────────────
  bool _pttActive = false;
  bool _handsFreeStreaming = false;
  DateTime? _recordingStartedAt;

  DateTime? get recordingStartedAt => _recordingStartedAt;

  // ── Barge-in ────────────────────────────────────────────────────────────
  // Hardware AEC (AndroidAudioSource.voiceCommunication) removes speaker echo
  // from the mic signal, so a simple amplitude threshold is sufficient.
  static const double _bargeInThreshold = 0.35;
  static const int _bargeInFramesNeeded = 5;
  int _bargeInConsecFrames = 0;
  bool _bargeInTriggered = false;

  // ── Wake-word ───────────────────────────────────────────────────────────
  Timer? _returnToListeningTimer;
  bool _wakeWordStarting = false;

  // ── Latency tracking ────────────────────────────────────────────────────
  DateTime? _pttReleasedAt;
  DateTime? _transcriptAt;
  DateTime? _responseStartAt;
  bool _firstAudioReceived = false;

  // ── App lifecycle ───────────────────────────────────────────────────────
  bool _appInBackground = false;
  bool _disposed = false;

  VoiceController({
    required AppState appState,
    required VoiceConnectionState connection,
    required ConversationState conversation,
    required AudioCoordinator audio,
    required PlayerService player,
    required BluetoothService bluetooth,
    required ConfigService config,
  })  : _appState = appState,
        _connection = connection,
        _conversation = conversation,
        _audio = audio,
        _player = player,
        _bluetooth = bluetooth,
        _config = config;

  // ═════════════════════════════════════════════════════════════════════════
  //  Init / dispose
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    _connection.addListener(_onConnectionStateChanged);

    await _player.init();
    await _player.setSpeed(_config.playbackSpeed);

    _startBluetoothMonitoring();
    unawaited(_connectIfNeeded().catchError(
        (e) => debugPrint('[VoiceController] _connectIfNeeded error: $e')));
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _connection.removeListener(_onConnectionStateChanged);
    _wsEventSub?.cancel();
    _wsAudioSub?.cancel();
    _recorderSub?.cancel();
    _bargeInSub?.cancel();
    _vadSub?.cancel();
    _wakeWordSub?.cancel();
    _playbackCompleteSub?.cancel();
    _proximitySub?.cancel();
    _bluetoothSub?.cancel();
    _returnToListeningTimer?.cancel();
    super.dispose();
  }

  /// Shorthand: update fields then notify, but only if not disposed.
  void _set(VoidCallback updates) {
    updates();
    if (!_disposed) notifyListeners();
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  App lifecycle
  // ═════════════════════════════════════════════════════════════════════════

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _appInBackground = true;
      if (_appState.backgroundListeningEnabled && _appState.wakeWordEnabled) {
        unawaited(_startWakeWordInBackground().catchError(
            (e) => debugPrint('[VoiceController] _startWakeWordInBackground error: $e')));
      } else {
        unawaited(_stopHandsFreeStreaming().catchError(
            (e) => debugPrint('[VoiceController] _stopHandsFreeStreaming error: $e')));
        unawaited(_audio.stopAll().catchError(
            (e) => debugPrint('[VoiceController] stopAll error: $e')));
        _appState.setRecording(false);
      }
    }
    if (state == AppLifecycleState.resumed) {
      _appInBackground = false;
      NotificationService.cancelBackgroundListeningNotification();
      unawaited(AudioModeService.stopForegroundService().catchError(
          (e) => debugPrint('[VoiceController] stopForegroundService error: $e')));
      unawaited(_connectIfNeeded().catchError(
          (e) => debugPrint('[VoiceController] _connectIfNeeded error: $e')));
    }
    if (state == AppLifecycleState.detached) {
      _connection.disconnect();
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  Connection lifecycle
  // ═════════════════════════════════════════════════════════════════════════

  void _onConnectionStateChanged() {
    if (_disposed) return;
    if (_connection.isConnected) {
      _subscribeToWebSocket();
      // If HF mode is enabled, ensure streaming has started. Idempotent —
      // _startHandsFreeStreaming guards via `_handsFreeStreaming` so calling
      // it again while already running is a no-op. This is what keeps the
      // mic listening after a settings-toggle reconnect or a fresh connect
      // where the connection wasn't up yet during init().
      if (_appState.handsFreeEnabled) {
        unawaited(_startHandsFreeStreaming().catchError(
            (e) => debugPrint('[VoiceController] _startHandsFreeStreaming error: $e')));
      }
    } else {
      unawaited(_stopHandsFreeStreaming().catchError(
          (e) => debugPrint('[VoiceController] _stopHandsFreeStreaming error: $e')));
      _set(() {
        _isResponding = false;
        _isProcessing = false;
        _currentTranscript = '';
        _currentResponse = '';
        _responseWasInterrupted = false;
      });
    }
  }

  Future<void> _connectIfNeeded() async {
    if (_connection.isConnected) {
      // Already connected — listener won't fire, so subscribe and start directly.
      _subscribeToWebSocket();
      if (_appState.handsFreeEnabled) {
        unawaited(_startHandsFreeStreaming().catchError(
            (e) => debugPrint('[VoiceController] _startHandsFreeStreaming error: $e')));
      }
    } else {
      await _connection.connect();
    }
  }

  void _subscribeToWebSocket() {
    _wsEventSub?.cancel();
    _eventChain = Future.value();
    _wsEventSub = _connection.eventStream?.listen((event) {
      _eventChain = _eventChain
          .then((_) => _handleEvent(event))
          .catchError(
              (e) => debugPrint('[VoiceController] Event handler error: $e'));
    });

    _wsAudioSub?.cancel();
    _wsAudioSub = _connection.audioStream?.listen((pcmData) {
      _player.bufferChunk(pcmData);
    });
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  WS event handling
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _handleEvent(WebSocketEvent event) async {
    if (_disposed) return;

    switch (event.type) {
      case EventType.transcript:
        _transcriptAt = DateTime.now();
        _set(() => _currentTranscript = event.data?['text'] as String? ?? '');
        break;

      case EventType.responseStart:
        _bargeInTriggered = false;
        _responseWasInterrupted = false;
        _responseStartAt = DateTime.now();
        _firstAudioReceived = false;
        await _player.startResponse();
        _set(() {
          _isResponding = true;
          _isProcessing = false;
          _currentResponse = '';
          if (_appState.handsFreeEnabled) {
            _appState.setHandsFreePhase(HandsFreePhase.speaking);
          }
        });
        break;

      case EventType.responseDelta:
        final delta = event.data?['text'] as String? ?? '';
        if (delta.isNotEmpty) {
          _set(() => _currentResponse += delta);
        }
        break;

      case EventType.audioStart:
        _player.startSentence();
        break;

      case EventType.audioEnd:
        if (!_firstAudioReceived) {
          _firstAudioReceived = true;
          _updateLatency();
        }
        await _player.playBuffered();
        break;

      case EventType.responseEnd:
        _appState.setHandsFreeListening(false);
        if (_responseWasInterrupted) {
          // Already saved the partial response at interrupt time — skip.
          _responseWasInterrupted = false;
          _set(() => _isResponding = false);
        } else {
          final fullText = event.data?['text'] as String? ?? '';
          if (fullText.isNotEmpty) _currentResponse = fullText;
          if (_appInBackground && fullText.isNotEmpty) {
            NotificationService.showResponseNotification(fullText);
          }
          await _saveResponse();
        }
        // After response ends in hands-free, go back to idle/wake word listening.
        // If TTS audio was received, PlayerService.onPlaybackEnded will trigger
        // _scheduleReturnToListening() after playback actually finishes.
        // If no audio was received (text-only response), schedule immediately.
        if (_appState.handsFreeEnabled) {
          if (!_firstAudioReceived || !_player.isPlaying) {
            _scheduleReturnToListening();
          }
        }
        break;

      case EventType.ttsOnlyStart:
        // TTS replay — reset player but don't show a responding indicator.
        await _player.startResponse();
        break;

      case EventType.ttsOnlyEnd:
        break;

      case EventType.listeningStart:
        _appState.setHandsFreeListening(true);
        _appState.setHandsFreePhase(HandsFreePhase.recording);
        break;

      case EventType.listeningEnd:
        _appState.setHandsFreeListening(false);
        _appState.setHandsFreePhase(HandsFreePhase.processing);
        _set(() => _isProcessing = true);
        break;

      case EventType.interruptAck:
        // Save partial response before clearing — responseEnd will skip saving.
        _responseWasInterrupted = true;
        await _saveResponse();
        _set(() {
          _isResponding = false;
          _isProcessing = false;
          _currentResponse = '';
          if (_appState.handsFreeEnabled) {
            // Don't set idle — let _scheduleReturnToListening() bring us back
            // to wake-word listening after the interrupt.
            _appState.setHandsFreePhase(HandsFreePhase.processing);
          }
        });
        if (_appState.handsFreeEnabled) {
          _scheduleReturnToListening();
        }
        break;

      case EventType.error:
        _set(() => _isProcessing = false);
        if (_appState.handsFreeEnabled) {
          _appState.setHandsFreePhase(HandsFreePhase.idle);
        }
        break;

      default:
        break;
    }
  }

  /// After a response ends in hands-free mode, return to wake word listening
  /// or idle state after a brief pause.
  Future<void> _scheduleReturnToListening() async {
    if (!_appState.wakeWordEnabled) {
      // No wake word — go straight back to recording so the audio sender
      // (gated by phase == recording) starts forwarding the next utterance.
      _appState.setHandsFreePhase(HandsFreePhase.recording);
      return;
    }
    // Cancel any previous stale callback before scheduling a new one.
    _returnToListeningTimer?.cancel();
    _returnToListeningTimer =
        Timer(const Duration(milliseconds: 500), () async {
      if (_disposed) return;
      if (!_appState.handsFreeEnabled || _isResponding) {
        // A new turn started (barge-in or rapid follow-up) — skip stale callback.
        return;
      }
      // Stop any active recorder before starting wake word listening
      // to prevent microphone conflicts
      await _audio.stopAll();
      _appState.setHandsFreePhase(HandsFreePhase.wakeWordListening);
      _startWakeWordListening();
    });
  }

  void _updateLatency() {
    final released = _pttReleasedAt;
    final transcript = _transcriptAt;
    final responseStart = _responseStartAt;
    if (released == null) return;
    _appState.setLastLatency(LatencyInfo(
      sttMs: transcript != null
          ? transcript.difference(released).inMilliseconds
          : null,
      llmMs: (transcript != null && responseStart != null)
          ? responseStart.difference(transcript).inMilliseconds
          : null,
      ttsMs: responseStart != null
          ? DateTime.now().difference(responseStart).inMilliseconds
          : null,
    ));
  }

  Future<void> _saveResponse() async {
    final transcript = _currentTranscript;
    final response = _currentResponse;
    if (transcript.isNotEmpty) {
      await _conversation.addMessage('user', transcript);
    }
    if (response.isNotEmpty) {
      await _conversation.addMessage('assistant', response);
    }
    _set(() {
      _currentTranscript = '';
      _currentResponse = '';
      _isResponding = false;
      _isProcessing = false;
    });
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  PTT
  // ═════════════════════════════════════════════════════════════════════════

  void onPttPressed() {
    // Fire-and-forget async from sync callback; all errors caught inside.
    () async {
      _pttActive = true;
      _recordingStartedAt = DateTime.now();
      _set(() => _isProcessing = false);

      if (!_connection.isConnected) {
        _pttActive = false;
        _recordingStartedAt = null;
        return;
      }

      try {
        if (_player.isPlaying) {
          await _player.interrupt();
          _connection.sendInterrupt();
        }

        await AudioModeService.setVoiceCommunicationMode();
        if (!_audio.isInitialized) await _audio.init();
        if (!_pttActive) return;

        _recorderSub?.cancel();
        _recorderSub = _audio.audioStream.listen((chunk) {
          if (_pttActive) _connection.sendAudio(chunk);
        });

        await _audio.startRecording();
        if (!_pttActive) {
          await _audio.stopRecording();
          _recorderSub?.cancel();
          return;
        }
        _appState.setRecording(true);
      } catch (e) {
        debugPrint('[VoiceController] PTT press error: $e');
        _pttActive = false;
        _recordingStartedAt = null;
        _set(() {});
      }
    }();
  }

  Future<void> onPttReleased() async {
    try {
      _pttActive = false;
      _pttReleasedAt = DateTime.now();
      _recordingStartedAt = null;
      _set(() => _isProcessing = true);

      await _audio.stopRecording();
      _appState.setRecording(false);
      _recorderSub?.cancel();
      if (!_appState.handsFreeEnabled) await AudioModeService.resetAudioMode();

      _connection.sendEndRecording(history: _conversation.recentHistory());
    } catch (e) {
      debugPrint('[VoiceController] PTT release error: $e');
      _appState.setRecording(false);
      _set(() => _isProcessing = false);
    }
  }

  /// Public interrupt — used by the PTT button's "tap to stop response" affordance.
  void interrupt() {
    _player.interrupt();
    _connection.sendInterrupt();
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  Hands-free streaming
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _startHandsFreeStreaming() async {
    if (_handsFreeStreaming) return;
    if (!_connection.isConnected) return;
    _handsFreeStreaming = true;
    try {
      // Enable auto-play for hands-free mode
      if (_appState.autoPlayEnabled) {
        _player.setAutoPlay(true);
      }

      // Wire up the mic re-enable callback so the microphone returns to
      // wake-word listening only AFTER TTS playback actually finishes.
      _player.onPlaybackEnded = () {
        debugPrint(
            '[VoiceController] onPlaybackEnded fired — scheduling return to listening');
        if (!_disposed && _appState.handsFreeEnabled && _appState.wakeWordEnabled) {
          _scheduleReturnToListening();
        }
      };

      // Switch Android audio to MODE_IN_COMMUNICATION so the hardware AEC
      // receives the speaker loopback reference and can cancel TTS echo.
      await AudioModeService.setVoiceCommunicationMode();

      // Start Bluetooth SCO if preferred and a BT headset is likely connected
      if (_appState.bluetoothPreferred) {
        await AudioModeService.startBluetoothSco();
      }

      if (!_audio.isInitialized) await _audio.init();
      if (_disposed) return;

      // Enable VAD on the recorder for hands-free mode (if setting is enabled)
      if (_appState.clientVadEnabled) {
        _audio.setVadEnabled(true);
      }
      _vadSub?.cancel();
      _vadSub = _audio.vadStateStream.listen((vadState) {
        if (vadState == VadState.speechEnd && _handsFreeStreaming) {
          _onHandsFreeSpeechEnd();
        }
      });

      // Barge-in: only enabled when the user opts in (requires headphones/earbuds
      // for reliable AEC — phone speaker causes false triggers without hardware AEC).
      _bargeInSub?.cancel();
      _bargeInConsecFrames = 0;
      if (_appState.bargeInEnabled) {
        _bargeInSub = _audio.amplitudeStream.listen((amplitude) {
          if (!_player.isPlaying) {
            _bargeInConsecFrames = 0;
            return;
          }
          if (amplitude >= _bargeInThreshold) {
            _bargeInConsecFrames++;
            if (_bargeInConsecFrames >= _bargeInFramesNeeded) {
              _bargeInConsecFrames = 0;
              if (_bargeInTriggered) return;
              _bargeInTriggered = true;
              debugPrint('[VoiceController] Barge-in detected, interrupting');
              _player.interrupt();
              _connection.sendInterrupt();
            }
          } else {
            _bargeInConsecFrames = 0;
          }
        });
      }

      // Phase transitions after playback are handled by _scheduleReturnToListening()
      // (triggered by responseEnd and/or onPlaybackEnded). Do NOT overwrite phase
      // here — it would clobber the wakeWordListening state set by
      // _scheduleReturnToListening().
      _playbackCompleteSub?.cancel();
      _playbackCompleteSub = _player.playbackCompleteStream.listen((_) {
        // Intentionally no-op: phase managed by _scheduleReturnToListening().
      });

      // Start proximity sensor if enabled
      if (_appState.proximitySensorEnabled) {
        _startProximitySensor();
      }

      // When wake word is enabled, DON'T start the main recorder yet.
      // Only start streaming audio to the server after wake word detection.
      if (!_appState.wakeWordEnabled) {
        _recorderSub?.cancel();
        _recorderSub = _audio.audioStream.listen((chunk) {
          // Phase guard: only send audio during recording phase.
          // Don't send mic audio while the speaker is playing — prevents echo loops.
          if (_appState.handsFreePhase == HandsFreePhase.recording &&
              !_player.isPlaying) {
            _connection.sendAudio(chunk);
          }
        });
        await _audio.startRecording();
      }

      // Set initial phase
      if (_appState.wakeWordEnabled) {
        _appState.setHandsFreePhase(HandsFreePhase.wakeWordListening);
        _startWakeWordListening();
      } else {
        _appState.setHandsFreePhase(HandsFreePhase.recording);
      }
    } catch (e) {
      _handsFreeStreaming = false;
      debugPrint('[VoiceController] _startHandsFreeStreaming error: $e');
      // Tear down anything we partially set up.
      try {
        _vadSub?.cancel();
        _bargeInSub?.cancel();
        _recorderSub?.cancel();
        _playbackCompleteSub?.cancel();
        _proximitySub?.cancel();
        await _audio.stopAll();
        await AudioModeService.stopBluetoothSco();
        await AudioModeService.resetAudioMode();
      } catch (cleanupErr) {
        debugPrint(
            '[VoiceController] _startHandsFreeStreaming cleanup error: $cleanupErr');
      }
      rethrow;
    }
  }

  Future<void> _stopHandsFreeStreaming() async {
    if (!_handsFreeStreaming) return;
    _handsFreeStreaming = false;
    _returnToListeningTimer?.cancel();
    _returnToListeningTimer = null;
    _bargeInSub?.cancel();
    _bargeInConsecFrames = 0;
    _recorderSub?.cancel();
    _vadSub?.cancel();
    _playbackCompleteSub?.cancel();
    _proximitySub?.cancel();

    _audio.setVadEnabled(false);
    await _audio.stopAll();
    _appState.setHandsFreeListening(false);
    _appState.setHandsFreePhase(HandsFreePhase.idle);
    _player.setAutoPlay(_appState.autoPlayEnabled);
    await AudioModeService.stopBluetoothSco();
    await AudioModeService.resetAudioMode();
    await _stopWakeWordListening();
    await AudioModeService.stopProximitySensor();
    await AudioModeService.stopForegroundService();
    _set(() => _isProcessing = false);
  }

  /// Called when VAD detects the user has stopped speaking.
  void _onHandsFreeSpeechEnd() {
    _connection.sendEndRecording(history: _conversation.recentHistory());
    _appState.setHandsFreePhase(HandsFreePhase.processing);
    _set(() => _isProcessing = true);
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  Wake word
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _startWakeWordListening() async {
    if (!_appState.wakeWordEnabled || !_appState.handsFreeEnabled) return;
    if (_wakeWordStarting) return;
    _wakeWordStarting = true;

    try {
      _removeWakeWordListener();

      // Stop any active recording first
      await _audio.stopAll();

      if (!_audio.isRecording || _audio.mode != AudioMode.wakeWord) {
        _audio.setWakePhrase(_appState.wakeWordPhrase);
        await _audio.startWakeWordListening();
      }

      // Listen for wake-word detections via the dedicated stream.
      _wakeWordSub?.cancel();
      _wakeWordSub = _audio.wakeWordDetectStream.listen((detectedPhrase) async {
        if (_disposed) return;
        debugPrint('[VoiceController] Wake word detected: $detectedPhrase');

        // Cancel the wake-word stream sub immediately to prevent re-entry
        _wakeWordSub?.cancel();
        _wakeWordSub = null;

        // Transition to recording phase
        _appState.setHandsFreePhase(HandsFreePhase.recording);
        _appState.setHandsFreeListening(true);

        // Now start the main recorder and begin streaming audio to server
        _recorderSub?.cancel();
        _recorderSub = _audio.audioStream.listen((chunk) {
          // Phase guard: only send during recording phase
          if (_appState.handsFreePhase == HandsFreePhase.recording &&
              !_player.isPlaying) {
            _connection.sendAudio(chunk);
          }
        });
        await _audio.startRecording();

        // Stop wake word listening while recording
        await _audio.stopWakeWordListening();
      });
    } catch (e) {
      debugPrint('[VoiceController] Wake word service error: $e');
    } finally {
      _wakeWordStarting = false;
    }
  }

  void _removeWakeWordListener() {
    _wakeWordSub?.cancel();
    _wakeWordSub = null;
  }

  Future<void> _stopWakeWordListening() async {
    _removeWakeWordListener();
    await _audio.stopWakeWordListening();
  }

  /// Start wake word listening in background with a persistent notification.
  Future<void> _startWakeWordInBackground() async {
    if (!_appState.backgroundListeningEnabled || !_appState.wakeWordEnabled) return;
    await AudioModeService.startForegroundService();
    await NotificationService.showBackgroundListeningNotification();
    _startWakeWordListening();
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  Proximity / Bluetooth
  // ═════════════════════════════════════════════════════════════════════════

  void _startProximitySensor() {
    if (!_appState.proximitySensorEnabled) return;

    () async {
      final started = await AudioModeService.startProximitySensor();
      if (!started) return;

      _proximitySub?.cancel();
      _proximitySub = AudioModeService.proximityStream.listen((isNear) {
        if (_disposed) return;
        _appState.setNearEar(isNear);
        if (isNear) {
          // Phone near ear — switch to earpiece
          _player.setUseEarpiece(true);
          AudioModeService.configureForEarpiece();
        } else {
          // Phone away from ear — switch to speaker
          _player.setUseEarpiece(false);
          AudioModeService.configureForSpeaker();
        }
      });
    }();
  }

  void _startBluetoothMonitoring() {
    _bluetoothSub?.cancel();
    _bluetoothSub = _bluetooth.connectionStream.listen((connected) {
      if (_disposed) return;
      _appState.setBluetoothConnected(connected);
    });
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  Public API used by MainScreen UI
  // ═════════════════════════════════════════════════════════════════════════

  /// Regenerate the last assistant response from the last user turn.
  void regenerateLastResponse() {
    if (!_connection.isConnected) return;
    final msgs = _conversation.messages;
    if (msgs.isEmpty) return;
    final lastUserIdx = msgs.lastIndexWhere((m) => m.role == 'user');
    if (lastUserIdx < 0) return;
    final lastUser = msgs[lastUserIdx];
    // History must not include the last user turn — it's re-sent as the text arg.
    final history = _conversation.recentHistory();
    final trimmedHistory = history.isNotEmpty && history.last['role'] == 'user'
        ? history.sublist(0, history.length - 1)
        : history;
    _connection.sendTextQuery(lastUser.content, history: trimmedHistory);
    _set(() {
      _isResponding = true;
      _currentResponse = '';
    });
  }

  void replayTts(String text) {
    _connection.sendTtsRequest(text);
  }

  void sendTextMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!_connection.isConnected) return;
    _connection.sendTextQuery(trimmed, history: _conversation.recentHistory());
    _set(() {
      _currentTranscript = trimmed;
      _isResponding = true;
      _currentResponse = '';
    });
  }
}
