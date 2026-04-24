import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

/// Recording service with optional Voice Activity Detection (VAD).
///
/// In PTT mode, the caller controls start/stop explicitly.
/// In hands-free mode, [startWithVad] enables auto-detection of speech
/// start/stop. The caller listens to [vadStateStream] for transitions:
///   * VadState.speechStart -> user started speaking
///   * VadState.speechEnd  -> user stopped speaking (silence detected)
class RecorderService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final StreamController<Uint8List> _audioStream = StreamController.broadcast();
  final StreamController<double> _amplitudeStream = StreamController.broadcast();
  final StreamController<VadState> _vadStateStream = StreamController.broadcast();

  static const int sampleRate = 16000;
  static const int numChannels = 1;

  StreamSubscription? _progressSub;
  bool _isRecording = false;
  bool _isInitialized = false;
  bool get isRecording => _isRecording;
  bool get isInitialized => _isInitialized;

  Stream<Uint8List> get audioStream => _audioStream.stream;
  Stream<double> get amplitudeStream => _amplitudeStream.stream;
  Stream<VadState> get vadStateStream => _vadStateStream.stream;

  // ── VAD state ────────────────────────────────────────────────────────────
  bool _vadEnabled = false;

  // VAD parameters (tuned for 80ms callback interval)
  static const double _vadEnergyThreshold = 0.04;
  static const int _vadStartFrames = 3;   // ~240ms of speech to trigger start
  static const int _vadStopFrames = 20;   // ~1.6s silence to trigger stop
  static const int _vadMinFrames = 8;     // ~640ms minimum utterance

  int _vadConsecSpeech = 0;
  int _vadConsecSilence = 0;
  int _vadTotalSpeechFrames = 0;
  bool _vadHasTriggeredStart = false;

  /// Enable or disable VAD processing on the amplitude stream.
  /// When enabled, [vadStateStream] emits speech start/stop events.
  void setVadEnabled(bool enabled) {
    if (_vadEnabled == enabled) return;
    _vadEnabled = enabled;
    _resetVad();
  }

  Future<bool> requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> init() async {
    if (_isInitialized) return;

    final hasPermission = await requestMicrophonePermission();
    if (!hasPermission) {
      throw Exception('Microphone permission required');
    }

    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 80));
    _progressSub = _recorder.onProgress?.listen((e) {
      final db = e.decibels ?? -160.0;
      final normalized = ((db + 80.0) / 70.0).clamp(0.0, 1.0);
      if (!_amplitudeStream.isClosed) {
        _amplitudeStream.add(normalized);
      }
      _processVadFrame(normalized);
    });

    _isInitialized = true;
  }

  // ── Standard PTT recording ───────────────────────────────────────────────

  Future<void> start() async {
    if (_isRecording) return;
    try {
      await _recorder.startRecorder(
        toStream: _audioStream.sink,
        codec: Codec.pcm16,
        numChannels: numChannels,
        sampleRate: sampleRate,
        bufferSize: 1024,
        audioSource: AudioSource.voice_communication,
      );
      _isRecording = true;
    } catch (e) {
      _isRecording = false;
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_isRecording) return;
    _isRecording = false;
    _resetVad();
    await _recorder.stopRecorder();
    if (!_amplitudeStream.isClosed) {
      _amplitudeStream.add(0.0);
    }
  }

  // ── VAD-enabled recording ────────────────────────────────────────────────

  /// Start recording with VAD. The recorder runs continuously, but [vadStateStream]
  /// emits [VadState.speechStart] when speech begins and [VadState.speechEnd]
  /// when silence persists after speech.
  Future<void> startWithVad() async {
    if (_isRecording) return;
    _vadEnabled = true;
    _resetVad();
    try {
      await _recorder.startRecorder(
        toStream: _audioStream.sink,
        codec: Codec.pcm16,
        numChannels: numChannels,
        sampleRate: sampleRate,
        bufferSize: 1024,
        audioSource: AudioSource.voice_communication,
      );
      _isRecording = true;
    } catch (e) {
      _isRecording = false;
      _vadEnabled = false;
      rethrow;
    }
  }

  /// Stop VAD recording. Resets VAD counters.
  Future<void> stopVad() async {
    _vadEnabled = false;
    await stop();
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
        if (!_vadStateStream.isClosed) {
          _vadStateStream.add(VadState.speechStart);
        }
      }
    } else {
      _vadConsecSilence++;
      _vadConsecSpeech = 0;

      if (_vadHasTriggeredStart &&
          _vadConsecSilence >= _vadStopFrames &&
          _vadTotalSpeechFrames >= _vadMinFrames) {
        // Speech has ended
        _vadHasTriggeredStart = false;
        _vadTotalSpeechFrames = 0;
        if (!_vadStateStream.isClosed) {
          _vadStateStream.add(VadState.speechEnd);
        }
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    await _progressSub?.cancel();
    await _audioStream.close();
    await _amplitudeStream.close();
    await _vadStateStream.close();
    await _recorder.closeRecorder();
  }
}

/// VAD state transitions.
enum VadState { speechStart, speechEnd }