import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for detecting a wake word ("Hey Ollama" / "Hey Kimi" / "Hey Beatrice" /
/// "Hey Computer") from the microphone stream using energy-based detection with
/// lightweight on-device processing. This is a self-contained fallback that works
/// without external wake-word model files. For production, replace with
/// porcupine_flutter or sherpa-onnx keyword spotting.
///
/// Strategy: Uses amplitude gating + multi-syllable energy pattern matching
/// on rolling FFT band energy to detect the phrase cadence of wake words.
///
/// The pre-built WakeWordService already handles the PCM stream analysis.
/// This version adds proper cooldowns, background-friendly operation, and
/// configurable wake phrases.
class WakeWordService extends ChangeNotifier {
  // ── State ────────────────────────────────────────────────────────────────

  bool _isActive = false;
  bool _isListening = false;
  bool _wakeWordDetected = false;
  String _lastDetectedWord = '';
  String _currentPhrase = 'Hey Ollama';

  bool get isActive => _isActive;
  bool get isListening => _isListening;
  bool get wakeWordDetected => _wakeWordDetected;
  String get lastDetectedWord => _lastDetectedWord;

  /// Set the wake phrase to detect. Supports: "Hey Ollama", "Hey Kimi",
  /// "Hey Beatrice", "Hey Computer".
  void setPhrase(String phrase) {
    // Normalize: handle snake_case values from settings dropdown too
    final normalized = phrase
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : w)
        .join(' ');
    _currentPhrase = normalized;
  }

  // ── Audio internals ──────────────────────────────────────────────────────

  FlutterSoundRecorder? _recorder;
  final StreamController<Uint8List> _audioStream = StreamController.broadcast();
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription? _progressSub;
  final StreamController<double> _amplitudeStream = StreamController.broadcast();

  static const int _sampleRate = 16000;
  static const int _numChannels = 1;

  // Rolling buffer: ~2s of 16kHz 16-bit mono = 64000 bytes
  static const int _bufferSize = 64000;
  final Uint8List _ringBuffer = Uint8List(_bufferSize);
  int _ringBufferPos = 0;
  int _ringBufferLen = 0;

  // Energy-based pre-detection
  static const double _energyThreshold = 0.06;
  static const int _minFramesAboveThreshold = 2;
  int _consecutiveFramesAbove = 0;
  bool _energyGateOpen = false;

  // Cooldown after a detection to avoid re-triggering
  DateTime? _lastDetectionTime;
  static const Duration _cooldown = Duration(seconds: 3);

  // Detection smoothing — require N frames of sustained pattern
  static const int _framesNeeded = 2;
  int _patternMatchCount = 0;

  // ── Wake word templates ───────────────────────────────────────────────────
  // Spectral energy fingerprints for wake phrases.
  // Each template is a sequence of 5-band energy snapshots (time-step x bands).
  // Captures the acoustic "fingerprint" of syllable sequences.

  // "Hey Ollama" = 4 syllables: HEY-oh-LAH-mah
  static final List<List<double>> _heyOllamaTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04], // HEY: front-heavy, plosive onset
    [0.28, 0.30, 0.22, 0.14, 0.06], // oh: mid-forward
    [0.22, 0.28, 0.26, 0.16, 0.08], // LAH: mid-low sustained
    [0.20, 0.26, 0.24, 0.20, 0.10], // mah: trailing low-mid
  ];

  // "Hey Kimi" = 3 syllables: HEY-KEE-mee
  static final List<List<double>> _heyKimiTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04], // HEY
    [0.20, 0.28, 0.30, 0.16, 0.06], // KEE: higher mid energy
    [0.22, 0.32, 0.24, 0.14, 0.08], // mee: rounded mid
  ];

  // "Hey Beatrice" = 4 syllables: HEY-BEA-trice (similar energy to Hey Ollama)
  static final List<List<double>> _heyBeatriceTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04], // HEY: front-heavy, plosive onset
    [0.26, 0.32, 0.24, 0.12, 0.06], // BEA: mid-forward, slightly rounded
    [0.24, 0.28, 0.26, 0.16, 0.06], // trice: crisp mid-high
    [0.20, 0.24, 0.22, 0.20, 0.14], // trailing low-mid
  ];

  // "Hey Computer" = 4 syllables: HEY-com-PUT-er
  static final List<List<double>> _heyComputerTemplate = [
    [0.38, 0.32, 0.18, 0.08, 0.04], // HEY: front-heavy, plosive onset
    [0.28, 0.32, 0.22, 0.12, 0.06], // com: compact mid
    [0.18, 0.22, 0.32, 0.20, 0.08], // PUT: higher mid energy, sharp
    [0.22, 0.26, 0.24, 0.18, 0.10], // er: trailing low-mid
  ];

  // Threshold for template match
  static const double _matchThreshold = 0.72;
  static const double _earlyMatchThreshold = 0.68;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Start continuous wake word listening.
  Future<void> start() async {
    if (_isActive) return;

    final hasPermission = await Permission.microphone.request();
    if (!hasPermission.isGranted) {
      throw Exception('Microphone permission required for wake word detection');
    }

    _recorder = FlutterSoundRecorder();
    await _recorder!.openRecorder();
    await _recorder!.setSubscriptionDuration(const Duration(milliseconds: 80));

    _progressSub = _recorder!.onProgress?.listen((e) {
      final db = e.decibels ?? -160.0;
      final normalized = ((db + 80.0) / 70.0).clamp(0.0, 1.0);
      if (!_amplitudeStream.isClosed) {
        _amplitudeStream.add(normalized);
      }
    });

    await _recorder!.startRecorder(
      toStream: _audioStream.sink,
      codec: Codec.pcm16,
      numChannels: _numChannels,
      sampleRate: _sampleRate,
      bufferSize: 1024,
      audioSource: AudioSource.voice_communication,
    );

    _isActive = true;
    _isListening = true;
    _ringBufferPos = 0;
    _ringBufferLen = 0;
    _energyGateOpen = false;
    _consecutiveFramesAbove = 0;
    _patternMatchCount = 0;

    _audioSub = _audioStream.stream.listen(_onAudioChunk);
    notifyListeners();
  }

  /// Stop wake word listening.
  Future<void> stop() async {
    if (!_isActive) return;
    _isActive = false;
    _isListening = false;

    await _audioSub?.cancel();
    _audioSub = null;
    await _progressSub?.cancel();
    _progressSub = null;

    try { await _recorder?.stopRecorder(); } catch (_) {}
    try { await _recorder?.closeRecorder(); } catch (_) {}
    _recorder = null;

    _ringBufferLen = 0;
    _patternMatchCount = 0;
    notifyListeners();
  }

  /// Acknowledge the wake word detection (resets the detected flag).
  void acknowledgeWakeWord() {
    _wakeWordDetected = false;
    notifyListeners();
  }

  /// Stream of amplitude levels for visual feedback.
  Stream<double> get amplitudeStream => _amplitudeStream.stream;

  @override
  void dispose() {
    stop().catchError((_) {});
    _audioStream.close().catchError((_) {});
    _amplitudeStream.close().catchError((_) {});
    super.dispose();
  }

  // ── Audio processing ─────────────────────────────────────────────────────

  void _onAudioChunk(Uint8List chunk) {
    if (!_isActive) return;

    // Add to ring buffer
    for (int i = 0; i < chunk.length; i++) {
      _ringBuffer[_ringBufferPos] = chunk[i];
      _ringBufferPos = (_ringBufferPos + 1) % _bufferSize;
      if (_ringBufferLen < _bufferSize) _ringBufferLen++;
    }

    // Compute RMS energy of this chunk
    final rms = _computeRms(chunk);
    if (rms > _energyThreshold) {
      _consecutiveFramesAbove++;
      if (_consecutiveFramesAbove >= _minFramesAboveThreshold) {
        _energyGateOpen = true;
      }
    } else {
      _consecutiveFramesAbove = max(0, _consecutiveFramesAbove - 1);
      if (_consecutiveFramesAbove == 0) {
        _energyGateOpen = false;
        _patternMatchCount = 0;
      }
    }

    // Only attempt wake word detection when energy gate is open
    if (_energyGateOpen && _ringBufferLen >= _bufferSize) {
      _checkForWakeWord();
    }
  }

  double _computeRms(Uint8List pcm16Data) {
    final numSamples = pcm16Data.length ~/ 2;
    if (numSamples == 0) return 0.0;

    double sumSquares = 0.0;
    for (int i = 0; i < numSamples; i++) {
      final byteOffset = i * 2;
      if (byteOffset + 1 >= pcm16Data.length) break;
      final lo = pcm16Data[byteOffset];
      final hi = pcm16Data[byteOffset + 1];
      final sample = (hi << 8) | lo;
      final signedSample = sample > 32767 ? sample - 65536 : sample;
      final normalized = signedSample / 32768.0;
      sumSquares += normalized * normalized;
    }
    return sqrt(sumSquares / numSamples);
  }

  void _checkForWakeWord() {
    // Check cooldown
    if (_lastDetectionTime != null &&
        DateTime.now().difference(_lastDetectionTime!) < _cooldown) {
      _energyGateOpen = false;
      _patternMatchCount = 0;
      return;
    }

    // Compute band energies from the ring buffer
    final snapshots = _computeEnergySnapshots(4); // 4 time steps
    if (snapshots.length < 4) return;

    // Check configured phrase
    final template = _templateForPhrase(_currentPhrase);
    final syllableCount = _syllableCountForPhrase(_currentPhrase);
    final useSnapshots = syllableCount == 4
        ? snapshots
        : snapshots.sublist(snapshots.length - syllableCount);

    final score = _dtwDistance(useSnapshots, template);
    if (score >= _matchThreshold ||
        (score >= _earlyMatchThreshold && ++_patternMatchCount >= _framesNeeded)) {
      _onWakeWordDetected(_currentPhrase);
      return;
    }

    // No match — slowly decay pattern match count
    if (_patternMatchCount > 0) _patternMatchCount--;
  }

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

  /// Compute a sequence of energy band snapshots from the ring buffer.
  /// Each snapshot represents a ~300ms window, capturing syllable-level dynamics.
  List<List<double>> _computeEnergySnapshots(int numSnapshots) {
    const int samplesPerSnapshot = 4800; // 300ms @ 16kHz 16-bit mono
    const int bytesPerSnapshot = samplesPerSnapshot * 2;

    final results = <List<double>>[];
    final List<int> window = [];

    // Extract most recent bytes from ring buffer
    final startByte = (_ringBufferPos - _ringBufferLen + _bufferSize) % _bufferSize;
    for (int i = 0; i < _ringBufferLen; i++) {
      window.add(_ringBuffer[(startByte + i) % _bufferSize]);
    }

    if (window.length < bytesPerSnapshot * numSnapshots) return [];

    // Divide into time windows and compute band energies for each
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

  List<double> _computeBandEnergies(Uint8List pcmData) {
    const int numBands = 5;
    final energies = List<double>.filled(numBands, 0.0);

    final numSamples = pcmData.length ~/ 2;
    if (numSamples < 128) return energies;

    // Convert to float samples
    final samples = List<double>.filled(numSamples, 0.0);
    for (int i = 0; i < numSamples; i++) {
      final off = i * 2;
      if (off + 1 >= pcmData.length) break;
      final lo = pcmData[off];
      final hi = pcmData[off + 1];
      final val = (hi << 8) | lo;
      samples[i] = (val > 32767 ? val - 65536 : val) / 32768.0;
    }

    // Simple 5-band energy using Goertzel-like narrowband filters
    // Frequencies at band centers: 150, 450, 900, 1800, 3200 Hz
    final freqs = [150.0, 450.0, 900.0, 1800.0, 3200.0];
    final sr = _sampleRate.toDouble();

    for (int b = 0; b < numBands; b++) {
      final k = 2 * cos(2 * pi * freqs[b] / sr);
      double s0 = 0, s1 = 0, s2 = 0;
      for (int n = 0; n < numSamples; n++) {
        s0 = samples[n] + k * s1 - s2;
        s2 = s1;
        s1 = s0;
      }
      // Power estimate
      energies[b] = s2 * s2 + s1 * s1 - k * s1 * s2;
    }

    // Normalize to sum to 1.0
    final total = energies.reduce((a, b) => a + b);
    if (total > 1e-12) {
      for (int i = 0; i < numBands; i++) {
        energies[i] = (energies[i] / total).clamp(0.0, 1.0);
      }
    }
    return energies;
  }

  /// Dynamic time warping distance normalized to [0,1] where 1 = perfect match.
  double _dtwDistance(List<List<double>> a, List<List<double>> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;

    final n = a.length;
    final m = b.length;
    final prev = List<double>.filled(m, double.infinity);
    final curr = List<double>.filled(m, 0);

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
    // Normalize: maximum possible per-step distance for 5D vectors bounded [0,1] is sqrt(5)
    final maxDist = sqrt(5.0) * max(n, m);
    if (maxDist <= 0) return 1.0;
    return (1.0 - (raw / maxDist)).clamp(0.0, 1.0);
  }

  double _euclideanDist(List<double> a, List<double> b) {
    double sum = 0;
    final len = min(a.length, b.length);
    for (int i = 0; i < len; i++) {
      final d = a[i] - b[i];
      sum += d * d;
    }
    return sqrt(sum);
  }

  void _onWakeWordDetected(String word) {
    _lastDetectionTime = DateTime.now();
    _wakeWordDetected = true;
    _lastDetectedWord = word;
    _energyGateOpen = false;
    _consecutiveFramesAbove = 0;
    _patternMatchCount = 0;
    print('[WakeWord] Detected: "$word"');
    notifyListeners();
  }
}
