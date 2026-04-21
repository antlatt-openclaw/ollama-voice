import 'package:flutter/services.dart';

/// Controls Android AudioManager mode so hardware AEC has a reference signal.
///
/// MODE_IN_COMMUNICATION tells the audio DSP that a voice call is active,
/// which wires up the loopback reference for AcousticEchoCanceler and makes
/// AudioSource.voice_communication actually cancel speaker echo.
class AudioModeService {
  static const _channel = MethodChannel('com.openclaw.voice/audio');

  /// Switch to MODE_IN_COMMUNICATION — call before starting hands-free mic.
  static Future<void> setVoiceCommunicationMode() async {
    try {
      await _channel.invokeMethod('setVoiceCommunicationMode');
    } catch (_) {
      // Non-Android platforms or older devices — safe to ignore.
    }
  }

  /// Restore MODE_NORMAL — call when hands-free stops.
  static Future<void> resetAudioMode() async {
    try {
      await _channel.invokeMethod('resetAudioMode');
    } catch (_) {}
  }
}
