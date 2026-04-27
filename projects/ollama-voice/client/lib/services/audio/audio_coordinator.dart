import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

/// Unified audio coordinator that owns a single [FlutterSoundRecorder] instance
/// and switches its output between wake-word detection and server streaming.
///
/// One mic owner avoids the race that an earlier split between separate
/// recorder + wake-word services hit, where both tried to open the microphone
/// simultaneously.
class AudioCoordinator extends ChangeNotifier {
  // ── Single recorder instance ───────────────────────────────────────────────
  FlutterSoundRecorder? _recorder;
  StreamSubscription? _progressSub;
  StreamSubscription<Uint8List>? _audioSub;

  // ── Stream controllers ───────────────────────────────────────────────────
  final StreamController<Uint8List> _audioStream = StreamController.broadcast();
  final StreamController<double> _amplitudeStream = StreamController.broadcast();
  final StreamController<VadState> _vadStateStream = StreamController.broadcast();

  static const int sampleRate = 16000;
  static const int numChannels = 1;

  // ── State ────────────────────────────────────────────────────────────────
  bool _isInitialized = false;
  bool _isRecording = false;
  AudioMode _mode = AudioMode.idle;

  bool get isInitialized => _isInitialized;
  bool get isRecording => _isRecording;
  AudioMode get mode => _mode;

  Stream<Uint8List> get audioStream => _audioStream.stream;
  Stream<double> get amplitudeStream => _amplitudeStream.stream;
  Stream<VadState> get vadStateStream => _vadStateStream.stream;

  // ── VAD state (used in recording mode) ─────────────────────────────────
  bool _vadEnabled = false;

  static const double _vadEnergyThreshold = 0.04;
  static const int _vadStartFrames = 3;   // ~240ms
  static const int _vadStopFrames = 20;   // ~1.6s
  static const int _vadMinFrames = 8;     // ~640ms

  int _vadConsecSpeech = 0;
  int _vadConsecSilence = 0;
  int _vadTotalSpeechFrames = 0;
  bool _vadHasTriggeredStart = false;

  // ── Wake-word state ──────────────────────────────────────────────────────
  String _wakePhrase = 'Hey Ollama';
  bool _wakeWordDetected = false;
  String _lastDetectedWord = '';

  bool get wakeWordDetected => _wakeWordDetected;
  String get lastDetectedWord => _lastDetectedWord;

  // ── Ring buffer for wake-word analysis ───────────────────────────────────
  static const int _bufferSize = 64000; // ~2s @ 16kHz 16-bit mono
  final Uint8List _ringBuffer = Uint8List(_bufferSize);
  int _ringBufferPos = 0;
  int _ringBufferLen = 0;

  static const double _wwEnergyThreshold = 0.06;
  static const int _wwMinFramesAbove = 2;
  int _wwConsecFramesAbove = 0;
  bool _wwEnergyGateOpen = false;

  DateTime? _lastDetectionTime;
  static const Duration _wwCooldown = Duration(seconds: 3);
  static const int _wwFramesNeeded = 2;
  int _wwPatternMatchCount = 0;

  // ── Error handling ───────────────────────────────────────────────────────
  final StreamController<String> _errorStream = StreamController.broadcast();
  Stream<String> get errorStream => _errorStream.stream;

  // ── Wake-word detection stream ──────────────────────────────────────────────
  // Emits the detected phrase each time a wake word is recognized.
  // This is more reliable than ChangeNotifier.addListener which fires on
  // every notifyListeners() call (e.g. every amplitude update).
  final StreamController<String> _wakeWordDetectStream = StreamController.broadcast();
  Stream<String> get wakeWordDetectStream => _wakeWordDetectStream.stream;

  // ═════════════════════════════════════════════════════════════════════════
  //  PUBLIC API
  // ═════════════════════════════════════════════════════════════════════════

  /// Initialise the single recorder (mic permission + openRecorder).
  Future<void> init() async {
    if (_isInitialized) return;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw Exception('Microphone permission required');
    }

    _recorder = FlutterSoundRecorder();
    await _recorder!.openRecorder();
    await _recorder!.setSubscriptionDuration(const Duration(milliseconds: 80));

    _progressSub = _recorder!.onProgress?.listen((e) {
      final db = e.decibels ?? -160.0;
      final normalized = ((db + 80.0) / 70.0).clamp(0.0, 1.0);
      if (!_amplitudeStream.isClosed) _amplitudeStream.add(normalized);

      // Route to mode-specific processing
      switch (_mode) {
        case AudioMode.recording:
          _processVadFrame(normalized);
          break;
        case AudioMode.wakeWord:
          // amplitude handled via _onAudioChunk, not here
          break;
        case AudioMode.idle:
          break;
      }
    });

    _isInitialized = true;
  }

  // ── Recording mode ─────────────────────────────────────────────────────────

  /// Start streaming audio to the server (PTT or hands-free recording phase).
  Future<void> startRecording({bool enableVad = false}) async {
    await _ensureRecorderReady();
    if (_isRecording && _mode == AudioMode.recording) return;

    // If currently in wake-word mode, stop that first
    if (_mode == AudioMode.wakeWord) {
      _audioSub?.cancel();
      _audioSub = null;
      await _stopRecorderOnly();
    }

    _mode = AudioMode.recording;
    _vadEnabled = enableVad;
    _resetVad();
    _resetWakeWord();

    try {
      await _recorder!.startRecorder(
        toStream: _audioStream.sink,
        codec: Codec.pcm16,
        numChannels: numChannels,
        sampleRate: sampleRate,
        bufferSize: 1024,
        audioSource: AudioSource.voice_communication,
      );
      _isRecording = true;
    } catch (e) {
      _mode = AudioMode.idle;
      _isRecording = false;
      _errorStream.add('startRecording failed: $e');
      rethrow;
    }
  }

  /// Stop the recording stream.
  Future<void> stopRecording() async {
    if (!_isRecording || _mode != AudioMode.recording) return;
    _isRecording = false;
    _vadEnabled = false;
    _resetVad();
    await _stopRecorderOnly();
    if (!_amplitudeStream.isClosed) _amplitudeStream.add(0.0);
  }

  // ── Wake-word mode ─────────────────────────────────────────────────────────

  /// Start listening for the wake word.
  Future<void> startWakeWordListening({String? phrase}) async {
    await _ensureRecorderReady();
    if (_isRecording && _mode == AudioMode.wakeWord) return;

    // If currently recording, stop that first
    if (_mode == AudioMode.recording) {
      await _stopRecorderOnly();
    }

    _mode = AudioMode.wakeWord;
    _resetWakeWord();
    if (phrase != null) _wakePhrase = phrase;

    try {
      await _recorder!.startRecorder(
        toStream: _audioStream.sink,
        codec: Codec.pcm16,
        numChannels: numChannels,
        sampleRate: sampleRate,
        bufferSize: 1024,
        audioSource: AudioSource.voice_communication,
      );
      _isRecording = true;

      // Subscribe to PCM chunks for wake-word analysis
      _audioSub?.cancel();
      _audioSub = _audioStream.stream.listen(_onWakeWordAudioChunk);
    } catch (e) {
      _mode = AudioMode.idle;
      _isRecording = false;
      _errorStream.add('startWakeWordListening failed: $e');
      rethrow;
    }
  }

  /// Stop wake-word listening.
  Future<void> stopWakeWordListening() async {
    if (_mode != AudioMode.wakeWord) return;
    _audioSub?.cancel();
    _audioSub = null;
    await _stopRecorderOnly();
    _resetWakeWord();
    _mode = AudioMode.idle;
  }

  /// Acknowledge a wake-word detection (resets the flag).
  void acknowledgeWakeWord() {
    _wakeWordDetected = false;
    notifyListeners();
  }

  /// Set the wake phrase to detect.
  void setWakePhrase(String phrase) {
    final normalized = phrase
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : w)
        .join(' ');
    _wakePhrase = normalized;
  }

  void setVadEnabled(bool enabled) {
    _vadEnabled = enabled;
    _resetVad();
  }

  // ── Shared stop ───────────────────────────────────────────────────────────

  /// Stop whatever is currently running and return to idle.
  Future<void> stopAll() async {
    _audioSub?.cancel();
    _audioSub = null;
    await _stopRecorderOnly();
    _mode = AudioMode.idle;
    _isRecording = false;
    _resetVad();
    _resetWakeWord();
    if (!_amplitudeStream.isClosed) _amplitudeStream.add(0.0);
  }

  // ── Dispose ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    // Synchronous teardown so any in-flight callbacks (recorder.onProgress,
    // _onWakeWordAudioChunk) hit closed-stream guards instead of racing with
    // super.dispose(). Cancel sources first, then close sinks.

    _progressSub?.cancel();          // stop new amplitude events from flowing
    _progressSub = null;
    _audioSub?.cancel();
    _audioSub = null;

    if (!_audioStream.isClosed) _audioStream.close();
    if (!_amplitudeStream.isClosed) _amplitudeStream.close();
    if (!_vadStateStream.isClosed) _vadStateStream.close();
    if (!_errorStream.isClosed) _errorStream.close();
    if (!_wakeWordDetectStream.isClosed) _wakeWordDetectStream.close();

    // Recorder shutdown is async but we don't need to await it — the streams
    // are already closed, so any pending events become no-ops.
    final recorder = _recorder;
    _recorder = null;
    _isRecording = false;
    _mode = AudioMode.idle;
    if (recorder != null) {
      unawaited(_shutdownRecorder(recorder));
    }

    super.dispose();
  }

  Future<void> _shutdownRecorder(FlutterSoundRecorder recorder) async {
    try {
      await recorder.stopRecorder();
    } catch (_) {}
    try {
      await recorder.closeRecorder();
    } catch (_) {}
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  PRIVATE HELPERS
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _ensureRecorderReady() async {
    if (!_isInitialized) await init();
  }

  Future<void> _stopRecorderOnly() async {
    try {
      await _recorder?.stopRecorder();
    } catch (_) {}
    _isRecording = false;
  }

  void _resetVad() {
    _vadConsecSpeech = 0;
    _vadConsecSilence = 0;
    _vadTotalSpeechFrames = 0;
    _vadHasTriggeredStart = false;
  }

  void _processVadFrame(double amplitude) {
    if (!_vadEnabled || !_isRecording) return;

    final isSpeech = amplitude >= _vadEnergyThreshold;

    if (isSpeech) {
      _vadConsecSpeech++;
      _vadConsecSilence = 0;
      _vadTotalSpeechFrames++;

      if (!_vadHasTriggeredStart && _vadConsecSpeech >= _vadStartFrames) {
        _vadHasTriggeredStart = true;
        if (!_vadStateStream.isClosed) _vadStateStream.add(VadState.speechStart);
      }
    } else {
      _vadConsecSilence++;
      _vadConsecSpeech = 0;

      if (_vadHasTriggeredStart &&
          _vadConsecSilence >= _vadStopFrames &&
          _vadTotalSpeechFrames >= _vadMinFrames) {
        _vadHasTriggeredStart = false;
        _vadTotalSpeechFrames = 0;
        if (!_vadStateStream.isClosed) _vadStateStream.add(VadState.speechEnd);
      }
    }
  }

  // ── Wake-word audio processing ───────────────────────────────────────────

  void _onWakeWordAudioChunk(Uint8List chunk) {
    if (_mode != AudioMode.wakeWord) return;

    // Fill ring buffer
    for (int i = 0; i < chunk.length; i++) {
      _ringBuffer[_ringBufferPos] = chunk[i];
      _ringBufferPos = (_ringBufferPos + 1) % _bufferSize;
      if (_ringBufferLen < _bufferSize) _ringBufferLen++;
    }

    // Energy gate
    final rms = _computeRms(chunk);
    if (rms > _wwEnergyThreshold) {
      _wwConsecFramesAbove++;
      if (_wwConsecFramesAbove >= _wwMinFramesAbove) _wwEnergyGateOpen = true;
    } else {
      _wwConsecFramesAbove = (_wwConsecFramesAbove > 0) ? _wwConsecFramesAbove - 1 : 0;
      if (_wwConsecFramesAbove == 0) {
        _wwEnergyGateOpen = false;
        _wwPatternMatchCount = 0;
      }
    }

    if (_wwEnergyGateOpen && _ringBufferLen >= _bufferSize) {
      _checkForWakeWord();
    }
  }

  double _computeRms(Uint8List pcm16) {
    final n = pcm16.length ~/ 2;
    if (n == 0) return 0.0;
    double sum = 0.0;
    for (int i = 0; i < n; i++) {
      final off = i * 2;
      if (off + 1 >= pcm16.length) break;
      final sample = (pcm16[off + 1] << 8) | pcm16[off];
      final signed = sample > 32767 ? sample - 65536 : sample;
      final norm = signed / 32768.0;
      sum += norm * norm;
    }
    return sqrt(sum / n);
  }

  void _checkForWakeWord() {
    if (_lastDetectionTime != null &&
        DateTime.now().difference(_lastDetectionTime!) < _wwCooldown) {
      _wwEnergyGateOpen = false;
      _wwPatternMatchCount = 0;
      return;
    }

    final snapshots = _computeEnergySnapshots(4);
    if (snapshots.length < 4) return;

    final template = _templateForPhrase(_wakePhrase);
    final syllables = _syllableCountForPhrase(_wakePhrase);
    final use = syllables == 4 ? snapshots : snapshots.sublist(snapshots.length - syllables);

    final score = _dtwDistance(use, template);
    if (score >= 0.72 || (score >= 0.68 && ++_wwPatternMatchCount >= _wwFramesNeeded)) {
      _onWakeWordDetected(_wakePhrase);
      return;
    }
    if (_wwPatternMatchCount > 0) _wwPatternMatchCount--;
  }

  void _onWakeWordDetected(String word) {
    _lastDetectionTime = DateTime.now();
    _wakeWordDetected = true;
    _lastDetectedWord = word;
    _wwEnergyGateOpen = false;
    _wwConsecFramesAbove = 0;
    _wwPatternMatchCount = 0;
    print('[AudioCoordinator] Wake word detected: "$word"');
    if (!_wakeWordDetectStream.isClosed) _wakeWordDetectStream.add(word);
    notifyListeners();
  }

  void _resetWakeWord() {
    _wwConsecFramesAbove = 0;
    _wwEnergyGateOpen = false;
    _wwPatternMatchCount = 0;
    _ringBufferPos = 0;
    _ringBufferLen = 0;
    _wakeWordDetected = false;
    _lastDetectedWord = '';
  }

  // ═════════════════════════════════════════════════════════════════════════
  //  WAKE-WORD TEMPLATES
  // ═════════════════════════════════════════════════════════════════════════

  static final List<List<double>> _heyOllamaTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04],
    [0.28, 0.30, 0.22, 0.14, 0.06],
    [0.22, 0.28, 0.26, 0.16, 0.08],
    [0.20, 0.26, 0.24, 0.20, 0.10],
  ];

  static final List<List<double>> _heyKimiTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04],
    [0.20, 0.28, 0.30, 0.16, 0.06],
    [0.22, 0.32, 0.24, 0.14, 0.08],
  ];

  static final List<List<double>> _heyBeatriceTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04],
    [0.26, 0.32, 0.24, 0.12, 0.06],
    [0.24, 0.28, 0.26, 0.16, 0.06],
    [0.20, 0.24, 0.22, 0.20, 0.14],
  ];

  static final List<List<double>> _heyComputerTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04],
    [0.28, 0.32, 0.22, 0.12, 0.06],
    [0.18, 0.22, 0.32, 0.20, 0.08],
    [0.22, 0.26, 0.24, 0.18, 0.10],
  ];

  List<List<double>> _templateForPhrase(String phrase) {
    switch (phrase) {
      case 'Hey Kimi':
        return _heyKimiTemplate;
      case 'Hey Beatrice':
        return _heyBeatriceTemplate;
      case 'Hey Computer':
        return _heyComputerTemplate;
      case 'Hey Ollama':
      default:
        return _heyOllamaTemplate;
    }
  }

  int _syllableCountForPhrase(String phrase) {
    switch (phrase) {
      case 'Hey Kimi':
        return 3;
      case 'Hey Ollama':
      case 'Hey Beatrice':
      case 'Hey Computer':
      default:
        return 4;
    }
  }

  List<List<double>> _computeEnergySnapshots(int numSnapshots) {
    const int samplesPerSnapshot = 4800; // 300ms
    const int bytesPerSnapshot = samplesPerSnapshot * 2;

    final results = <List<double>>[];
    final window = <int>[];

    final start = (_ringBufferPos - _ringBufferLen + _bufferSize) % _bufferSize;
    for (int i = 0; i < _ringBufferLen; i++) {
      window.add(_ringBuffer[(start + i) % _bufferSize]);
    }

    if (window.length < bytesPerSnapshot * numSnapshots) return [];

    for (int s = 0; s < numSnapshots; s++) {
      final offset = window.length - (numSnapshots - s) * bytesPerSnapshot;
      final slice = window.sublist(
        offset.clamp(0, window.length),
        (offset + bytesPerSnapshot).clamp(0, window.length),
      );
      results.add(_computeBandEnergies(Uint8List.fromList(slice)));
    }
    return results;
  }

  List<double> _computeBandEnergies(Uint8List pcm) {
    const int numBands = 5;
    final energies = List<double>.filled(numBands, 0.0);

    final n = pcm.length ~/ 2;
    if (n < 128) return energies;

    final samples = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      final off = i * 2;
      if (off + 1 >= pcm.length) break;
      final val = (pcm[off + 1] << 8) | pcm[off];
      samples[i] = (val > 32767 ? val - 65536 : val) / 32768.0;
    }

    final freqs = [150.0, 450.0, 900.0, 1800.0, 3200.0];
    final sr = sampleRate.toDouble();

    for (int b = 0; b < numBands; b++) {
      final k = 2 * cos(2 * pi * freqs[b] / sr);
      double s0 = 0, s1 = 0, s2 = 0;
      for (int nIdx = 0; nIdx < n; nIdx++) {
        s0 = samples[nIdx] + k * s1 - s2;
        s2 = s1;
        s1 = s0;
      }
      energies[b] = s2 * s2 + s1 * s1 - k * s1 * s2;
    }

    final total = energies.reduce((a, b) => a + b);
    if (total > 1e-12) {
      for (int i = 0; i < numBands; i++) {
        energies[i] = (energies[i] / total).clamp(0.0, 1.0);
      }
    }
    return energies;
  }

  double _dtwDistance(List<List<double>> a, List<List<double>> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final n = a.length;
    final m = b.length;
    final prev = List<double>.filled(m, double.infinity);
    final curr = List<double>.filled(m, 0.0);

    for (int i = 0; i < n; i++) {
      for (int j = 0; j < m; j++) {
        final cost = _euclideanDist(a[i], b[j]);
        final diag = j > 0 ? prev[j - 1] : double.infinity;
        final up = prev[j];
        final left = j > 0 ? curr[j - 1] : double.infinity;
        final best = [diag, up, left].reduce((x, y) => x < y ? x : y);
        curr[j] = cost + (best.isFinite ? best : 0);
      }
      for (int j = 0; j < m; j++) prev[j] = curr[j];
    }

    final raw = curr[m - 1];
    final maxDist = sqrt(5.0) * (n > m ? n : m);
    if (maxDist <= 0) return 1.0;
    return (1.0 - (raw / maxDist)).clamp(0.0, 1.0);
  }

  double _euclideanDist(List<double> a, List<double> b) {
    double sum = 0.0;
    final len = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < len; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return sqrt(sum);
  }
}

// ── Enums ──────────────────────────────────────────────────────────────────

enum AudioMode { idle, recording, wakeWord }

enum VadState { speechStart, speechEnd }
