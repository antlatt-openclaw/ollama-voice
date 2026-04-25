import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/websocket_event.dart';
import '../providers/app_state.dart' as app;
import '../providers/connection_state.dart'
    show VoiceConnectionState;
import '../providers/conversation_state.dart';
import '../services/audio/audio_coordinator.dart';
import '../services/audio/player_service.dart';
import '../services/audio/bluetooth_service.dart';
import '../services/audio/audio_mode_service.dart';
import '../services/config/config_service.dart';
import '../services/notification_service.dart';
import '../theme/colors.dart';
import '../widgets/push_to_talk_button.dart';
import '../widgets/connection_status.dart';
import '../widgets/message_list.dart';
import '../widgets/playback_controls.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  StreamSubscription? _wsEventSub;
  StreamSubscription? _wsAudioSub;
  StreamSubscription? _recorderSub;
  StreamSubscription? _bargeInSub;
  StreamSubscription? _vadSub;
  StreamSubscription? _wakeWordSub;
  StreamSubscription? _playbackCompleteSub;
  StreamSubscription? _proximitySub;
  StreamSubscription? _bluetoothSub;

  // Serializes async event handling so events are never processed concurrently.
  Future<void> _eventChain = Future.value();

  String _currentTranscript = '';
  String _currentResponse = '';
  bool _isResponding = false;
  bool _isProcessing = false;
  bool _isTextInput = false;
  bool _pttActive = false;
  bool _handsFreeStreaming = false;
  bool _responseWasInterrupted = false;

  final TextEditingController _textController = TextEditingController();

  // Barge-in detection: N consecutive high-amplitude frames triggers interrupt.
  // Hardware AEC (AndroidAudioSource.voiceCommunication) removes speaker echo
  // from the mic signal, so a simple threshold is sufficient.
  static const double _bargeInThreshold = 0.35;
  static const int _bargeInFramesNeeded = 5;
  int _bargeInConsecFrames = 0;

  // Guard against stale _scheduleReturnToListening() callbacks
  Timer? _returnToListeningTimer;

  // Guard against re-entering wake-word start while one is in-flight
  bool _wakeWordStarting = false;

  // Recording UX
  DateTime? _recordingStartedAt;

  // Latency tracking
  DateTime? _pttReleasedAt;
  DateTime? _transcriptAt;
  DateTime? _responseStartAt;
  bool _firstAudioReceived = false;

  bool _bargeInTriggered = false;

  // Background notification guard
  bool _appInBackground = false;

  // Track whether connection listener was registered (guarded addPostFrameCallback).
  bool _connectionListenerAdded = false;

  // Search
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initServices();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context
            .read<VoiceConnectionState>()
            .addListener(_onConnectionStateChanged);
        _connectionListenerAdded = true;
        _applyWakeLock();
      }
    });
  }

  void _applyWakeLock() {
    final enabled = context.read<app.AppState>().wakeLockEnabled;
    enabled ? WakelockPlus.enable() : WakelockPlus.disable();
  }

  void _onConnectionStateChanged() {
    if (!mounted) return;
    final conn = context.read<VoiceConnectionState>();
    if (conn.isConnected) {
      _subscribeToWebSocket();
      final appState = context.read<app.AppState>();
    } else {
      unawaited(_stopHandsFreeStreaming().catchError((e) => print('[MainScreen] _stopHandsFreeStreaming error: $e')));
      setState(() {
        _isResponding = false;
        _isProcessing = false;
        _currentTranscript = '';
        _currentResponse = '';
        _responseWasInterrupted = false;
      });
    }
  }

  Future<void> _initServices() async {
    final player = context.read<PlayerService>();
    final config = context.read<ConfigService>();
    await player.init();
    await player.setSpeed(config.playbackSpeed);
    _startBluetoothMonitoring();
    unawaited(_connectIfNeeded().catchError((e) => print('[MainScreen] _connectIfNeeded error: $e')));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_connectionListenerAdded) {
      context
          .read<VoiceConnectionState>()
          .removeListener(_onConnectionStateChanged);
      _connectionListenerAdded = false;
    }
    _wsEventSub?.cancel();
    _wsAudioSub?.cancel();
    _recorderSub?.cancel();
    _bargeInSub?.cancel();
    _vadSub?.cancel();
    _removeWakeWordListener();
    _playbackCompleteSub?.cancel();
    _proximitySub?.cancel();
    _bluetoothSub?.cancel();
    _searchController.dispose();
    _textController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final appState = context.read<app.AppState>();

    if (state == AppLifecycleState.paused) {
      _appInBackground = true;

      if (appState.backgroundListeningEnabled && appState.wakeWordEnabled) {
        // Keep listening for wake word in background with notification
        unawaited(_startWakeWordInBackground().catchError((e) => print('[MainScreen] _startWakeWordInBackground error: $e')));
      } else {
        // Stop all audio when going to background
        unawaited(_stopHandsFreeStreaming().catchError((e) => print('[MainScreen] _stopHandsFreeStreaming error: $e')));
        unawaited(context.read<AudioCoordinator>().stopAll().catchError((e) => print('[MainScreen] stopAll error: $e')));
        appState.setRecording(false);
      }
    }
    if (state == AppLifecycleState.resumed) {
      _appInBackground = false;
      NotificationService.cancelBackgroundListeningNotification();
      unawaited(AudioModeService.stopForegroundService().catchError((e) => print('[MainScreen] stopForegroundService error: $e')));
      unawaited(_connectIfNeeded().catchError((e) => print('[MainScreen] _connectIfNeeded error: $e')));
    }
    if (state == AppLifecycleState.detached) {
      context.read<VoiceConnectionState>().disconnect();
    }
  }

  Future<void> _connectIfNeeded() async {
    final conn = context.read<VoiceConnectionState>();
    if (conn.isConnected) {
      // Already connected — listener won't fire, so subscribe and start directly.
      _subscribeToWebSocket();
      if (context.read<app.AppState>().handsFreeEnabled) {
        unawaited(_startHandsFreeStreaming().catchError((e) => print('[MainScreen] _startHandsFreeStreaming error: $e')));
      }
    } else {
      await conn.connect();
    }
  }

  void _subscribeToWebSocket() {
    final conn = context.read<VoiceConnectionState>();

    _wsEventSub?.cancel();
    _eventChain = Future.value();
    _wsEventSub = conn.eventStream?.listen((event) {
      _eventChain = _eventChain
          .then((_) => _handleEvent(event))
          .catchError((e) => print('[MainScreen] Event handler error: $e'));
    });

    _wsAudioSub?.cancel();
    _wsAudioSub = conn.audioStream?.listen((pcmData) {
      context.read<PlayerService>().bufferChunk(pcmData);
    });
  }

  Future<void> _handleEvent(WebSocketEvent event) async {
    if (!mounted) return;
    final appState = context.read<app.AppState>();

    switch (event.type) {
      case EventType.transcript:
        _transcriptAt = DateTime.now();
        setState(() =>
            _currentTranscript = event.data?['text'] as String? ?? '');
        break;

      case EventType.responseStart:
        _bargeInTriggered = false;
        _responseWasInterrupted = false;
        _responseStartAt = DateTime.now();
        _firstAudioReceived = false;
        if (mounted) await context.read<PlayerService>().startResponse();
        if (mounted) setState(() {
          _isResponding = true;
          _isProcessing = false;
          _currentResponse = '';
          // Update hands-free phase
          if (appState.handsFreeEnabled) {
            appState.setHandsFreePhase(app.HandsFreePhase.speaking);
          }
        });
        break;

      case EventType.responseDelta:
        final delta = event.data?['text'] as String? ?? '';
        if (delta.isNotEmpty && mounted) {
          setState(() => _currentResponse += delta);
        }
        break;

      case EventType.audioStart:
        if (mounted) context.read<PlayerService>().startSentence();
        break;

      case EventType.audioEnd:
        if (!_firstAudioReceived) {
          _firstAudioReceived = true;
          _updateLatency();
        }
        if (mounted) await context.read<PlayerService>().playBuffered();
        break;

      case EventType.responseEnd:
        if (mounted) {
          appState.setHandsFreeListening(false);
          if (_responseWasInterrupted) {
            // Already saved the partial response at interrupt time — skip.
            _responseWasInterrupted = false;
            setState(() => _isResponding = false);
          } else {
            final fullText = event.data?['text'] as String? ?? '';
            if (fullText.isNotEmpty) setState(() => _currentResponse = fullText);
            if (_appInBackground && fullText.isNotEmpty) {
              NotificationService.showResponseNotification(fullText);
            }
            await _saveResponse();
          }

          // After response ends in hands-free, go back to idle/wake word listening
          if (appState.handsFreeEnabled) {
            _scheduleReturnToListening();
          }
        }
        break;

      case EventType.ttsOnlyStart:
        // TTS replay — reset player but don't show a responding indicator.
        if (mounted) await context.read<PlayerService>().startResponse();
        break;

      case EventType.ttsOnlyEnd:
        break;

      case EventType.listeningStart:
        if (mounted) {
          appState.setHandsFreeListening(true);
          appState.setHandsFreePhase(app.HandsFreePhase.recording);
        }
        break;

      case EventType.listeningEnd:
        if (mounted) {
          appState.setHandsFreeListening(false);
          appState.setHandsFreePhase(app.HandsFreePhase.processing);
          setState(() => _isProcessing = true);
        }
        break;

      case EventType.interruptAck:
        // Save partial response before clearing — responseEnd will skip saving.
        _responseWasInterrupted = true;
        await _saveResponse();
        if (mounted) setState(() {
          _isResponding = false;
          _isProcessing = false;
          _currentResponse = '';
          if (appState.handsFreeEnabled) {
            appState.setHandsFreePhase(app.HandsFreePhase.idle);
          }
        });
        break;

      case EventType.error:
        if (mounted) {
          setState(() => _isProcessing = false);
          if (appState.handsFreeEnabled) {
            appState.setHandsFreePhase(app.HandsFreePhase.idle);
          }
        }
        break;

      default:
        break;
    }
  }

  /// After a response ends in hands-free mode, return to wake word listening
  /// or idle state after a brief pause.
  Future<void> _scheduleReturnToListening() async {
    final appState = context.read<app.AppState>();
    if (!appState.wakeWordEnabled) {
      appState.setHandsFreePhase(app.HandsFreePhase.idle);
      return;
    }
    // Cancel any previous stale callback before scheduling a new one.
    _returnToListeningTimer?.cancel();
    _returnToListeningTimer = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      final appState = context.read<app.AppState>();
      if (!appState.handsFreeEnabled || _isResponding) {
        // A new turn started (barge-in or rapid follow-up) — skip stale callback.
        return;
      }
      // Stop any active recorder before starting wake word listening
      // to prevent microphone conflicts
      await context.read<AudioCoordinator>().stopAll();
      appState.setHandsFreePhase(app.HandsFreePhase.wakeWordListening);
      _startWakeWordListening();
    });
  }

  void _updateLatency() {
    final released = _pttReleasedAt;
    final transcript = _transcriptAt;
    final responseStart = _responseStartAt;
    if (released == null) return;
    context.read<app.AppState>().setLastLatency(app.LatencyInfo(
          sttMs:
              transcript != null ? transcript.difference(released).inMilliseconds : null,
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
    final convState = context.read<ConversationState>();

    if (transcript.isNotEmpty) {
      await convState.addMessage('user', transcript);
    }
    if (response.isNotEmpty) {
      await convState.addMessage('assistant', response);
    }

    if (mounted) {
      setState(() {
        _currentTranscript = '';
        _currentResponse = '';
        _isResponding = false;
        _isProcessing = false;
      });
    }
  }

  // ── PTT ──────────────────────────────────────────────────────────────────

  void _onPttPressed() {
    // Fire-and-forget async from sync callback; all errors are caught inside.
    () async {
    _pttActive = true;
    _recordingStartedAt = DateTime.now();
    if (mounted) setState(() => _isProcessing = false);

    final recorder = context.read<AudioCoordinator>();
    final conn = context.read<VoiceConnectionState>();
    final appState = context.read<app.AppState>();

    if (!conn.isConnected) {
      _pttActive = false;
      _recordingStartedAt = null;
      return;
    }

    try {
      final player = context.read<PlayerService>();
      if (player.isPlaying) {
        await player.interrupt();
        conn.sendInterrupt();
      }

      await AudioModeService.setVoiceCommunicationMode();
      if (!recorder.isInitialized) await recorder.init();
      if (!_pttActive) return;

      _recorderSub?.cancel();
      _recorderSub = recorder.audioStream
          .listen((chunk) { if (_pttActive) conn.sendAudio(chunk); });

      await recorder.startRecording();
      if (!_pttActive) {
        await recorder.stopRecording();
        _recorderSub?.cancel();
        return;
      }
      appState.setRecording(true);
    } catch (e) {
      print('[PTT] Press error: $e');
      _pttActive = false;
      _recordingStartedAt = null;
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone unavailable')),
        );
      }
    }
    }();
  }

  void _onPttReleased() async {
    try {
      _pttActive = false;
      _pttReleasedAt = DateTime.now();
      _recordingStartedAt = null;
      if (mounted) setState(() => _isProcessing = true);

      final appState = context.read<app.AppState>();
      final convState = context.read<ConversationState>();
      final conn = context.read<VoiceConnectionState>();
      await context.read<AudioCoordinator>().stopRecording();
      appState.setRecording(false);
      _recorderSub?.cancel();
      if (!appState.handsFreeEnabled) await AudioModeService.resetAudioMode();

      conn.sendEndRecording(history: convState.recentHistory());
    } catch (e) {
      print('[MainScreen] PTT release error: $e');
      if (mounted) {
        context.read<app.AppState>().setRecording(false);
        setState(() => _isProcessing = false);
      }
    }
  }

  // ── Hands-free streaming ─────────────────────────────────────────────────

  Future<void> _startHandsFreeStreaming() async {
    if (_handsFreeStreaming) return;
    final recorder = context.read<AudioCoordinator>();
    final conn = context.read<VoiceConnectionState>();
    final player = context.read<PlayerService>();
    final appState = context.read<app.AppState>();
    if (!conn.isConnected) return;
    _handsFreeStreaming = true;

    // Enable auto-play for hands-free mode
    if (appState.autoPlayEnabled) {
      player.setAutoPlay(true);
    }

    // Switch Android audio to MODE_IN_COMMUNICATION so the hardware AEC
    // receives the speaker loopback reference and can cancel TTS echo.
    await AudioModeService.setVoiceCommunicationMode();

    // Start Bluetooth SCO if preferred and a BT headset is likely connected
    if (appState.bluetoothPreferred) {
      await AudioModeService.startBluetoothSco();
    }

    if (!recorder.isInitialized) await recorder.init();
    if (!mounted) return;

    // Enable VAD on the recorder for hands-free mode (if setting is enabled)
    if (appState.clientVadEnabled) {
      recorder.setVadEnabled(true);
    }
    _vadSub?.cancel();
    _vadSub = context.read<AudioCoordinator>().vadStateStream.listen((vadState) {
      if (vadState == VadState.speechEnd && _handsFreeStreaming) {
        // User stopped speaking — send the end_recording signal
        _onHandsFreeSpeechEnd();
      }
    });

    // Barge-in: only enabled when the user opts in (requires headphones/earbuds
    // for reliable AEC — phone speaker causes false triggers without hardware AEC).
    _bargeInSub?.cancel();
    _bargeInConsecFrames = 0;
    final bargeInEnabled = appState.bargeInEnabled;
    if (bargeInEnabled) {
      _bargeInSub = context.read<AudioCoordinator>().amplitudeStream.listen((amplitude) {
        if (!player.isPlaying) {
          _bargeInConsecFrames = 0;
          return;
        }
        if (amplitude >= _bargeInThreshold) {
          _bargeInConsecFrames++;
          if (_bargeInConsecFrames >= _bargeInFramesNeeded) {
            _bargeInConsecFrames = 0;
            if (_bargeInTriggered) return;
            _bargeInTriggered = true;
            print('[MainScreen] Barge-in detected, interrupting');
            player.interrupt();
            conn.sendInterrupt();
          }
        } else {
          _bargeInConsecFrames = 0;
        }
      });
    }

    // Monitor playback completion for hands-free phase transitions.
    // responseEnd already schedules the return to listening; we only update
    // the phase here to avoid creating duplicate delayed callbacks.
    _playbackCompleteSub?.cancel();
    _playbackCompleteSub = player.playbackCompleteStream.listen((_) {
      if (appState.handsFreeEnabled && mounted) {
        appState.setHandsFreePhase(app.HandsFreePhase.idle);
      }
    });

    // Start proximity sensor if enabled
    if (appState.proximitySensorEnabled) {
      _startProximitySensor();
    }

    // When wake word is enabled, DON'T start the main recorder yet.
    // Only start streaming audio to the server after wake word detection.
    if (!appState.wakeWordEnabled) {
      _recorderSub?.cancel();
      _recorderSub = context.read<AudioCoordinator>().audioStream.listen((chunk) {
        // Phase guard: only send audio during recording phase.
        // Don't send mic audio while the speaker is playing — prevents echo loops.
        if (appState.handsFreePhase == app.HandsFreePhase.recording &&
            !player.isPlaying) {
          conn.sendAudio(chunk);
        }
      });
      await recorder.startRecording();
    }

    // Set initial phase
    if (appState.wakeWordEnabled) {
      appState.setHandsFreePhase(app.HandsFreePhase.wakeWordListening);
      _startWakeWordListening();
    } else {
      appState.setHandsFreePhase(app.HandsFreePhase.recording);
    }
    } catch (e) {
      _handsFreeStreaming = false;
      print('[MainScreen] _startHandsFreeStreaming error: $e');
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

    final recorder = context.read<AudioCoordinator>();
    final appState = context.read<app.AppState>();
    final player = context.read<PlayerService>();

    recorder.setVadEnabled(false);
    await recorder.stopAll();
    appState.setHandsFreeListening(false);
    appState.setHandsFreePhase(app.HandsFreePhase.idle);
    player.setAutoPlay(false);
    await AudioModeService.stopBluetoothSco();
    await AudioModeService.resetAudioMode();
    await _stopWakeWordListening();
    await AudioModeService.stopProximitySensor();
    await AudioModeService.stopForegroundService();
    if (mounted) setState(() => _isProcessing = false);
  }

  /// Called when VAD detects the user has stopped speaking.
  void _onHandsFreeSpeechEnd() {
    final conn = context.read<VoiceConnectionState>();
    final convState = context.read<ConversationState>();
    final appState = context.read<app.AppState>();

    // Send end_recording to trigger server processing
    conn.sendEndRecording(history: convState.recentHistory());
    appState.setHandsFreePhase(app.HandsFreePhase.processing);
    setState(() => _isProcessing = true);
  }

  // ── Wake Word ────────────────────────────────────────────────────────────

  Future<void> _startWakeWordListening() async {
    final appState = context.read<app.AppState>();
    if (!appState.wakeWordEnabled || !appState.handsFreeEnabled) return;
    if (_wakeWordStarting) return; // already in-flight
    _wakeWordStarting = true;

    try {
      // Remove any previous wake-word listener first
      _removeWakeWordListener();

      final coordinator = context.read<AudioCoordinator>();

      // Stop any active recording first
      await coordinator.stopAll();

      if (!coordinator.isRecording || coordinator.mode != AudioMode.wakeWord) {
        coordinator.setWakePhrase(appState.wakeWordPhrase);
        await coordinator.startWakeWordListening();
      }

      // Listen for wake-word detections via the dedicated stream.
      // Using a stream instead of ChangeNotifier.addListener avoids firing
      // on every amplitude update — only fires on actual detections.
      _wakeWordSub?.cancel();
      _wakeWordSub = coordinator.wakeWordDetectStream.listen((detectedPhrase) async {
        if (!mounted) return;
        print('[MainScreen] Wake word detected: $detectedPhrase');

        // Cancel the wake-word stream sub immediately to prevent re-entry
        _wakeWordSub?.cancel();
        _wakeWordSub = null;

        // Transition to recording phase
        final appState = context.read<app.AppState>();
        appState.setHandsFreePhase(app.HandsFreePhase.recording);
        appState.setHandsFreeListening(true);

        // Now start the main recorder and begin streaming audio to server
        final conn = context.read<VoiceConnectionState>();
        _recorderSub?.cancel();
        _recorderSub = coordinator.audioStream.listen((chunk) {
          final phase = context.read<app.AppState>().handsFreePhase;
          final player = context.read<PlayerService>();
          // Phase guard: only send during recording phase
          if (phase == app.HandsFreePhase.recording && !player.isPlaying) {
            conn.sendAudio(chunk);
          }
        });
        await coordinator.startRecording();

        // Stop wake word listening while recording
        await coordinator.stopWakeWordListening();
      });
    } catch (e) {
      print('[MainScreen] Wake word service error: $e');
    } finally {
      _wakeWordStarting = false;
    }
  }

  void _removeWakeWordListener() {
    _wakeWordSub?.cancel();
    _wakeWordSub = null;
  }

  Future<void> _stopWakeWordListeningOnly() async {
    _removeWakeWordListener();
    await context.read<AudioCoordinator>().stopWakeWordListening();
  }

  Future<void> _stopWakeWordListening() async {
    _removeWakeWordListener();
    await context.read<AudioCoordinator>().stopWakeWordListening();
  }

  /// Start wake word listening in background with a persistent notification.
  /// NOTE: Background listening works on Android <12 via notification.
  /// On Android 12+, it may be limited without a proper foreground service.
  Future<void> _startWakeWordInBackground() async {
    final appState = context.read<app.AppState>();
    if (!appState.backgroundListeningEnabled || !appState.wakeWordEnabled) return;

    await AudioModeService.startForegroundService();
    await NotificationService.showBackgroundListeningNotification();
    _startWakeWordListening();
  }

  // ── Proximity Sensor ──────────────────────────────────────────────────────

  void _startProximitySensor() {
    final appState = context.read<app.AppState>();
    if (!appState.proximitySensorEnabled) return;

    () async {
      final started = await AudioModeService.startProximitySensor();
      if (!started) return;

      _proximitySub?.cancel();
      _proximitySub = AudioModeService.proximityStream.listen((isNear) {
        if (!mounted) return;
        appState.setNearEar(isNear);
        final player = context.read<PlayerService>();

        if (isNear) {
          // Phone near ear — switch to earpiece
          player.setUseEarpiece(true);
          AudioModeService.configureForEarpiece();
        } else {
          // Phone away from ear — switch to speaker
          player.setUseEarpiece(false);
          AudioModeService.configureForSpeaker();
        }
      });
    }();
  }

  // ── Bluetooth Monitoring ────────────────────────────────────────────────────

  void _startBluetoothMonitoring() {
    final appState = context.read<app.AppState>();
    final bluetoothService = context.read<BluetoothService>();
    _bluetoothSub?.cancel();
    // Use the BluetoothService's connection stream
    _bluetoothSub = bluetoothService.connectionStream.listen((connected) {
      if (!mounted) return;
      appState.setBluetoothConnected(connected);
    });
  }

  // ── Regenerate ───────────────────────────────────────────────────────────

  void _regenerateLastResponse() {
    final conn = context.read<VoiceConnectionState>();
    if (!conn.isConnected) return;
    final convState = context.read<ConversationState>();
    final msgs = convState.messages;
    if (msgs.isEmpty) return;
    final lastUserIdx = msgs.lastIndexWhere((m) => m.role == 'user');
    if (lastUserIdx < 0) return;
    final lastUser = msgs[lastUserIdx];
    // History must not include the last user turn — it's re-sent as the text arg.
    final history = convState.recentHistory();
    final trimmedHistory = history.isNotEmpty && history.last['role'] == 'user'
        ? history.sublist(0, history.length - 1)
        : history;
    conn.sendTextQuery(
          lastUser.content,
          history: trimmedHistory,
        );
    setState(() {
      _isResponding = true;
      _currentResponse = '';
    });
  }

  // ── TTS replay ───────────────────────────────────────────────────────────

  void _replayTts(String text) {
    context.read<VoiceConnectionState>().sendTtsRequest(text);
  }

  // ── Search ───────────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
  }

  // ── Text input ───────────────────────────────────────────────────────────

  void _sendTextMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    final conn = context.read<VoiceConnectionState>();
    if (!conn.isConnected) return;
    _textController.clear();
    final convState = context.read<ConversationState>();
    conn.sendTextQuery(text, history: convState.recentHistory());
    setState(() {
      _currentTranscript = text;
      _isResponding = true;
      _currentResponse = '';
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<app.AppState>();
    final connState = context.watch<VoiceConnectionState>();
    final convState = context.watch<ConversationState>();
    final player = context.watch<PlayerService>();

    return Scaffold(
      appBar: _buildAppBar(appState, convState),
      drawer: _ConversationDrawer(
        conversations: convState.conversations,
        activeId: convState.activeConversationId,
        onSelect: (id) async {
          await convState.loadConversation(id);
          if (mounted) Navigator.pop(context);
        },
        onNew: () async {
          await convState.startNewConversation();
          if (mounted) Navigator.pop(context);
        },
        onDelete: (id) => convState.deleteConversation(id),
      ),
      body: Column(
        children: [
          const ConnectionStatusBar(),

          if (appState.showDebugOverlay && appState.lastLatency != null)
            _LatencyOverlay(info: appState.lastLatency!),

          Expanded(
            child: MessageList(
              messages: convState.messages,
              currentTranscript: _currentTranscript,
              currentResponse: _currentResponse,
              isResponding: _isResponding,
              fontSize: appState.fontSize,
              searchQuery: _searchQuery,
              onRegenerateLastResponse: _regenerateLastResponse,
              onReplayTts: _replayTts,
            ),
          ),

          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: PlaybackControlsBar(),
          ),

          if (_isTextInput)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  12, 8, 8, MediaQuery.of(context).padding.bottom + 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      autofocus: true,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onSubmitted: (_) => _sendTextMessage(),
                      enabled: connState.isConnected,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.send_rounded),
                    onPressed:
                        connState.isConnected ? _sendTextMessage : null,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: EdgeInsets.fromLTRB(
                  24, 12, 24, MediaQuery.of(context).padding.bottom + 24),
              child: PushToTalkButton(
                isRecording: appState.isRecording,
                isPlaying: player.isPlaying,
                isConnected: connState.isConnected,
                tapToggleMode: appState.tapToggleMode,
                isHandsFreeMode: appState.handsFreeEnabled,
                isHandsFreeListening: appState.isHandsFreeListening,
                isResponding: _isResponding,
                isProcessing: _isProcessing,
                handsFreePhase: appState.handsFreePhase,
                wakeWordEnabled: appState.wakeWordEnabled,
                amplitudeStream: appState.isRecording
                    ? context.read<AudioCoordinator>().amplitudeStream
                    : null,
                recordingStartedAt: _recordingStartedAt,
                onPressed: _onPttPressed,
                onReleased: _onPttReleased,
                onInterrupt: () {
                  context.read<PlayerService>().interrupt();
                  context.read<VoiceConnectionState>().sendInterrupt();
                },
              ),
            ),
        ],
      ),
    );
  }

  AppBar _buildAppBar(app.AppState appState, ConversationState convState) {
    if (_isSearching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _toggleSearch,
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search messages…',
            border: InputBorder.none,
          ),
          onChanged: (q) => setState(() => _searchQuery = q),
        ),
        actions: [
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() {
                _searchQuery = '';
                _searchController.clear();
              }),
            ),
        ],
      );
    }

    final convName = convState.activeConversationName;
    final agent = appState.activeAgent;
    final agentName = agent.isEmpty
        ? 'Default'
        : agent[0].toUpperCase() + agent.substring(1);
    return AppBar(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            convName ?? 'Ollama Voice',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          Text(
            agentName,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.secondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.add_comment_outlined),
          tooltip: 'New conversation',
          onPressed: () => convState.startNewConversation(),
        ),
        IconButton(
          icon: Icon(
              _isTextInput ? Icons.mic_none_rounded : Icons.keyboard_rounded),
          tooltip: _isTextInput ? 'Switch to voice' : 'Switch to text',
          onPressed: () => setState(() => _isTextInput = !_isTextInput),
        ),
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: _toggleSearch,
        ),
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () => _showSettings(context),
        ),
      ],
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, sc) => _SettingsSheet(scrollController: sc),
      ),
    );
  }
}

// ── Conversation drawer ──────────────────────────────────────────────────────

class _ConversationDrawer extends StatelessWidget {
  final List<Conversation> conversations;
  final String? activeId;
  final void Function(String id) onSelect;
  final VoidCallback onNew;
  final void Function(String id) onDelete;

  const _ConversationDrawer({
    required this.conversations,
    required this.activeId,
    required this.onSelect,
    required this.onNew,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Text('Conversations',
                      style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add_comment_outlined),
                    tooltip: 'New conversation',
                    onPressed: onNew,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: conversations.isEmpty
                  ? const Center(
                      child: Text('No conversations yet',
                          style: TextStyle(color: AppColors.textSecondary)))
                  : ListView.builder(
                      itemCount: conversations.length,
                      itemBuilder: (ctx, i) {
                        final conv = conversations[i];
                        final isActive = conv.id == activeId;
                        return Dismissible(
                          key: Key(conv.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            color: AppColors.error.withValues(alpha: 0.15),
                            child: const Icon(Icons.delete_outline,
                                color: AppColors.error),
                          ),
                          confirmDismiss: (_) async {
                            return await showDialog<bool>(
                              context: ctx,
                              builder: (d) => AlertDialog(
                                title: const Text('Delete conversation?'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(d, false),
                                      child: const Text('Cancel')),
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(d, true),
                                      child: const Text('Delete',
                                          style: TextStyle(
                                              color: AppColors.error))),
                                ],
                              ),
                            ) ??
                                false;
                          },
                          onDismissed: (_) => onDelete(conv.id),
                          child: ListTile(
                            selected: isActive,
                            selectedTileColor:
                                AppColors.primary.withValues(alpha: 0.12),
                            leading: const Icon(Icons.chat_bubble_outline,
                                size: 20),
                            title: Text(
                              conv.name ?? 'New conversation',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              conv.lastMessage != null
                                  ? '${conv.lastMessage!} · ${_relativeTime(conv.updatedAt)}'
                                  : _relativeTime(conv.updatedAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () => onSelect(conv.id),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }
}

// ── Latency overlay ──────────────────────────────────────────────────────────

class _LatencyOverlay extends StatelessWidget {
  final app.LatencyInfo info;
  const _LatencyOverlay({required this.info});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: Colors.black.withValues(alpha: 0.3),
      child: Text(
        'STT ${_ms(info.sttMs)}  •  LLM ${_ms(info.llmMs)}  •  TTS ${_ms(info.ttsMs)}',
        style: const TextStyle(
            color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
      ),
    );
  }

  String _ms(int? v) => v != null ? '${v}ms' : '—';
}

// ── Settings sheet ───────────────────────────────────────────────────────────

class _SettingsSheet extends StatelessWidget {
  final ScrollController scrollController;
  const _SettingsSheet({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<app.AppState>();
    final config = context.read<ConfigService>();
    final convState = context.read<ConversationState>();
    final conn = context.read<VoiceConnectionState>();

    return ListView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, MediaQuery.of(context).padding.bottom + 24),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        // ── CHAT ─────────────────────────────────────────────────────────
        _SectionHeader('CHAT'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const Icon(Icons.format_size, size: 18),
            const SizedBox(width: 8),
            const Text('Font size'),
            const Spacer(),
            Text('${appState.fontSize.round()}px',
                style: const TextStyle(color: AppColors.textSecondary)),
          ]),
        ),
        Slider(
          value: appState.fontSize,
          min: 11,
          max: 22,
          divisions: 11,
          onChanged: (v) => appState.setFontSize(v),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.delete_outline),
          title: const Text('Clear Conversation'),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Clear conversation?'),
                content: const Text('All messages will be deleted.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Clear',
                          style: TextStyle(color: AppColors.error))),
                ],
              ),
            );
            if (ok == true && context.mounted) {
              await context.read<ConversationState>().clearActiveConversation();
              if (context.mounted) Navigator.pop(context);
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.ios_share_outlined),
          title: const Text('Export Conversation'),
          onTap: () {
            final text = convState.exportAsText();
            if (text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No messages to export')));
              return;
            }
            Share.share(text, subject: 'Ollama Voice Conversation');
          },
        ),

        const Divider(height: 24),

        // ── INPUT ─────────────────────────────────────────────────────────
        _SectionHeader('INPUT'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.hearing_rounded),
          title: const Text('Hands-free mode'),
          subtitle: const Text('Always listening — no button needed'),
          value: appState.handsFreeEnabled,
          onChanged: (v) async {
            await appState.setHandsFreeEnabled(v);
            if (context.mounted) {
              Navigator.pop(context);
              await conn.manualReconnect();
            }
          },
        ),

        // ── Wake Word ────────────────────────────────────────────────────
        if (appState.handsFreeEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.campaign_rounded),
            title: const Text('Wake word detection'),
            subtitle: const Text('Say "Hey Ollama" to start — off for privacy'),
            value: appState.wakeWordEnabled,
            onChanged: (v) => appState.setWakeWordEnabled(v),
          ),
          if (appState.wakeWordEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 56, bottom: 8),
              child: DropdownButtonFormField<String>(
                value: appState.wakeWordPhrase,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Wake phrase',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: const [
                  DropdownMenuItem(value: 'hey_ollama', child: Text('Hey Ollama')),
                  DropdownMenuItem(value: 'hey_kimi', child: Text('Hey Kimi')),
                  DropdownMenuItem(value: 'hey_beatrice', child: Text('Hey Beatrice')),
                  DropdownMenuItem(value: 'hey_computer', child: Text('Hey Computer')),
                ],
                onChanged: (v) {
                  if (v != null) appState.setWakeWordPhrase(v);
                },
              ),
            ),
        ],

        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.touch_app_outlined),
          title: const Text('Tap to toggle'),
          subtitle: const Text('Tap once to start, again to stop'),
          value: appState.tapToggleMode,
          onChanged: appState.handsFreeEnabled ? null : (v) => appState.setTapToggleMode(v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.headphones_outlined),
          title: const Text('Barge-in'),
          subtitle: const Text('Speak to interrupt response — use with headphones'),
          value: appState.bargeInEnabled,
          onChanged: appState.handsFreeEnabled
              ? (v) async {
                  await appState.setBargeInEnabled(v);
                  if (context.mounted) await conn.manualReconnect();
                }
              : null,
        ),

        if (appState.handsFreeEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.play_circle_outline),
            title: const Text('Auto-play responses'),
            subtitle: const Text('TTS plays automatically without tapping play'),
            value: appState.autoPlayEnabled,
            onChanged: (v) {
              appState.setAutoPlayEnabled(v);
              context.read<PlayerService>().setAutoPlay(v);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.graphic_eq),
            title: const Text('Client-side VAD'),
            subtitle: const Text('Detect speech start/stop locally to reduce latency'),
            value: appState.clientVadEnabled,
            onChanged: (v) => appState.setClientVadEnabled(v),
          ),
        ],

        const Divider(height: 24),

        // ── OUTPUT ────────────────────────────────────────────────────────
        _SectionHeader('OUTPUT'),

        if (appState.handsFreeEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.phone_in_talk_outlined),
            title: const Text('Proximity sensor'),
            subtitle: const Text('Switch to earpiece when phone is near ear'),
            value: appState.proximitySensorEnabled,
            onChanged: (v) => appState.setProximitySensorEnabled(v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.bluetooth_audio),
            title: const Text('Background listening'),
            subtitle: const Text('Listen for wake word when app is in background'),
            value: appState.backgroundListeningEnabled,
            onChanged: appState.wakeWordEnabled
                ? (v) => appState.setBackgroundListeningEnabled(v)
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.bluetooth_connected),
            title: const Text('Prefer Bluetooth'),
            subtitle: Text(
              appState.bluetoothConnected
                  ? 'Bluetooth headset connected'
                  : 'Route audio via Bluetooth when available',
              style: TextStyle(
                color: appState.bluetoothConnected
                    ? Colors.green
                    : AppColors.textSecondary,
              ),
            ),
            value: appState.bluetoothPreferred,
            onChanged: (v) => appState.setBluetoothPreferred(v),
          ),
        ],

        const Divider(height: 24),

        // ── AGENT ─────────────────────────────────────────────────────────
        _SectionHeader('AGENT'),
        ...ConfigService.availableAgents.map((agent) {
          final selected = appState.activeAgent == agent;
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: selected
                  ? AppColors.primary
                  : AppColors.primary.withValues(alpha: 0.12),
              child: Text(
                agent[0].toUpperCase(),
                style: TextStyle(
                  color: selected ? Colors.white : AppColors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(agent[0].toUpperCase() + agent.substring(1)),
            subtitle: Text(
              _agentDescriptions[agent] ?? '',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: selected
                ? const Icon(Icons.check_circle_rounded,
                    color: AppColors.primary, size: 20)
                : null,
            onTap: () async {
              await appState.setActiveAgent(agent);
              if (context.mounted) {
                Navigator.pop(context);
                await conn.manualReconnect();
              }
            },
          );
        }),

        const Divider(height: 24),

        // ── APPEARANCE ────────────────────────────────────────────────────
        _SectionHeader('APPEARANCE'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            const Icon(Icons.palette_outlined, size: 18),
            const SizedBox(width: 8),
            const Text('Theme'),
            const Spacer(),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode, size: 16),
                    label: Text('Dark')),
                ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode, size: 16),
                    label: Text('Light')),
                ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.phone_android, size: 16),
                    label: Text('Auto')),
              ],
              selected: {appState.themeMode},
              onSelectionChanged: (s) => appState.setThemeMode(s.first),
            ),
          ]),
        ),

        const Divider(height: 24),

        // ── POWER ─────────────────────────────────────────────────────────
        _SectionHeader('POWER'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.screen_lock_portrait_outlined),
          title: const Text('Keep screen on'),
          value: appState.wakeLockEnabled,
          onChanged: (v) {
            appState.setWakeLockEnabled(v);
            v ? WakelockPlus.enable() : WakelockPlus.disable();
          },
        ),

        const Divider(height: 24),

        // ── DEVELOPER ─────────────────────────────────────────────────────
        _SectionHeader('DEVELOPER'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.timer_outlined),
          title: const Text('Latency overlay'),
          subtitle: const Text('Show STT / LLM / TTS timing'),
          value: appState.showDebugOverlay,
          onChanged: (v) => appState.setShowDebugOverlay(v),
        ),

        const Divider(height: 24),

        // ── CONNECTION ────────────────────────────────────────────────────
        _SectionHeader('CONNECTION'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns),
          title: const Text('Server URL'),
          subtitle: Text(config.serverUrl,
              overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.edit_outlined, size: 16,
              color: AppColors.textSecondary),
          onTap: () async {
            final changed = await _showEditDialog(
              context,
              title: 'Server URL',
              initialValue: config.serverUrl,
            );
            if (changed != null && context.mounted) {
              await config.setServerUrl(changed);
              Navigator.pop(context);
              await conn.manualReconnect();
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.key),
          title: const Text('Auth Token'),
          subtitle: Text(config.hasAuthToken ? '••••••••' : 'Not set'),
          trailing: const Icon(Icons.edit_outlined, size: 16,
              color: AppColors.textSecondary),
          onTap: () async {
            final changed = await _showEditDialog(
              context,
              title: 'Auth Token',
              initialValue: config.authToken,
              obscured: true,
            );
            if (changed != null && context.mounted) {
              await config.setAuthToken(changed);
              Navigator.pop(context);
              await conn.manualReconnect();
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.psychology),
          title: const Text('System Prompt'),
          subtitle: Text('Tap to customize AI personality',
              overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.edit_outlined, size: 16,
              color: AppColors.textSecondary),
          onTap: () async {
            final changed = await _showEditDialog(
              context,
              title: 'System Prompt',
              initialValue: config.systemPrompt,
              multiline: true,
            );
            if (changed != null && context.mounted) {
              // Save locally as cache
              await config.setSystemPrompt(changed);
              // Send to server for persistence (no reconnect needed)
              conn.sendSetConfig(systemPrompt: changed);
              Navigator.pop(context);
            }
          },
        ),
      ],
    );
  }
}

const _agentDescriptions = {
  'default': 'Uncensored Ollama model',
};

Future<String?> _showEditDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  bool obscured = false,
  bool multiline = false,
}) async {
  final controller = TextEditingController(text: initialValue);
  bool visible = !obscured;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: !visible,
          autofocus: true,
          maxLines: multiline ? 8 : 1,
          decoration: InputDecoration(
            suffixIcon: obscured
                ? IconButton(
                    icon: Icon(
                        visible ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setS(() => visible = !visible),
                  )
                : null,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    ),
  );
  controller.dispose();
  return (result != null && result.isNotEmpty) ? result : null;
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}