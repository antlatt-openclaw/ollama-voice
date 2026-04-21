import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';

class RecorderService {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final StreamController<Uint8List> _audioStream = StreamController.broadcast();
  final StreamController<double> _amplitudeStream = StreamController.broadcast();

  static const int sampleRate = 16000;
  static const int numChannels = 1;

  StreamSubscription? _progressSub;
  bool _isRecording = false;
  bool _isInitialized = false;
  bool get isRecording => _isRecording;
  bool get isInitialized => _isInitialized;

  Stream<Uint8List> get audioStream => _audioStream.stream;
  Stream<double> get amplitudeStream => _amplitudeStream.stream;

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
    // Fire amplitude updates every 80 ms for waveform display.
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 80));
    _progressSub = _recorder.onProgress?.listen((e) {
      final db = e.decibels ?? -160.0;
      // Normalize -160..0 dBFS to 0.0..1.0, clamp to reasonable speech range.
      final normalized = ((db + 80.0) / 70.0).clamp(0.0, 1.0);
      if (!_amplitudeStream.isClosed) {
        _amplitudeStream.add(normalized);
      }
    });

    _isInitialized = true;
  }

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
    await _recorder.stopRecorder();
    // Push silence so the waveform decays visually.
    if (!_amplitudeStream.isClosed) {
      _amplitudeStream.add(0.0);
    }
  }

  Future<void> dispose() async {
    // Stop recording first so native callbacks stop firing
    await stop();
    await _progressSub?.cancel();
    // Close streams before closing recorder to prevent native callbacks
    // from writing to closed sinks after recorder is freed
    await _audioStream.close();
    await _amplitudeStream.close();
    // Now safe to close the recorder — no active callbacks remain
    await _recorder.closeRecorder();
  }
}
