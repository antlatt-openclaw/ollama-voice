import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Controls audio routing (speaker / earpiece / Bluetooth) and proximity sensor
/// detection for hands-free conversations.
///
/// On Android, the MethodChannel wires up MODE_IN_COMMUNICATION so the
/// hardware AEC reference loopback works.
///
/// Proximity sensor: when the phone is held near the ear, automatically switches
/// audio output to the earpiece and disables the speaker to prevent feedback.
///
/// Bluetooth: enables SCO (Synchronous Connection-Oriented) link for headset
/// mic input when a Bluetooth headset is connected.
class AudioModeService {
  static const _channel = MethodChannel('com.openclaw.voice/audio');

  // ── Proximity sensor (static) ─────────────────────────────────────────────

  static StreamSubscription? _proximitySub;
  static bool _proximityNear = false;
  static bool _proximityEnabled = false;
  static final StreamController<bool> _proximityStream = StreamController.broadcast();

  /// Stream of proximity sensor events: true = near (phone to ear), false = far.
  static Stream<bool> get proximityStream => _proximityStream.stream;
  static bool get proximityNear => _proximityNear;

  /// Start proximity sensor monitoring. Returns true if successfully started.
  static Future<bool> startProximitySensor() async {
    if (_proximityEnabled) return true;
    _proximityEnabled = true;
    _proximitySub?.cancel();

    if (!Platform.isAndroid) {
      _proximityEnabled = false;
      return false;
    }

    try {
      _proximitySub = EventChannel('com.openclaw.voice/proximity')
          .receiveBroadcastStream()
          .listen((event) {
        final near = event == 1 || event == true;
        if (near != _proximityNear) {
          _proximityNear = near;
          if (!_proximityStream.isClosed) {
            _proximityStream.add(near);
          }
        }
      });
      return true;
    } catch (e) {
      print('[AudioModeService] Proximity sensor not available: $e');
      _proximityEnabled = false;
      return false;
    }
  }

  /// Stop proximity sensor monitoring.
  static Future<void> stopProximitySensor() async {
    _proximityEnabled = false;
    _proximitySub?.cancel();
    _proximitySub = null;
    if (_proximityNear) {
      _proximityNear = false;
      if (!_proximityStream.isClosed) {
        _proximityStream.add(false);
      }
    }
  }

  // ── Android AudioManager mode ────────────────────────────────────────────

  /// Switch to MODE_IN_COMMUNICATION — call before starting hands-free mic.
  /// Returns true if the platform handler responded, false otherwise.
  static Future<bool> setVoiceCommunicationMode() async {
    try {
      await _channel.invokeMethod('setVoiceCommunicationMode');
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Restore MODE_NORMAL — call when hands-free stops.
  static Future<bool> resetAudioMode() async {
    try {
      await _channel.invokeMethod('resetAudioMode');
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Bluetooth SCO ──────────────────────────────────────────────────────

  /// Start Bluetooth SCO (Synchronous Connection-Oriented) audio connection.
  /// This enables the Bluetooth headset's microphone input and routes audio
  /// output to the headset. Required for hands-free with Bluetooth headsets.
  static Future<bool> startBluetoothSco() async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod('startBluetoothSco');
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Stop Bluetooth SCO connection — call when hands-free stops or headset
  /// disconnects.
  static Future<bool> stopBluetoothSco() async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod('stopBluetoothSco');
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Foreground Service ─────────────────────────────────────────────────

  /// Start the native foreground service to keep the app alive in background
  /// on Android 10+ during wake word listening.
  static Future<bool> startForegroundService() async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod('startForegroundService');
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Stop the native foreground service.
  static Future<bool> stopForegroundService() async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod('stopForegroundService');
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Audio routing configuration ──────────────────────────────────────────

  /// Configure audio session for earpiece output (phone held to ear).
  static Future<void> configureForEarpiece() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech().copyWith(
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
      ));
      if (Platform.isAndroid) {
        await _channel.invokeMethod('setEarpieceRoute');
      }
    } on MissingPluginException {
      // Platform not implemented — audio_session still works
    } catch (e) {
      print('[AudioModeService] configureForEarpiece error: $e');
    }
  }

  /// Configure audio session for speaker output (default).
  static Future<void> configureForSpeaker() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      if (Platform.isAndroid) {
        await _channel.invokeMethod('setSpeakerRoute');
      }
    } on MissingPluginException {
      // Platform not implemented — audio_session still works
    } catch (e) {
      print('[AudioModeService] configureForSpeaker error: $e');
    }
  }

  // ── Bluetooth connection stream ──────────────────────────────────────────

  /// Stream that emits `true` when a Bluetooth audio device (headset/earbuds)
  /// is connected, and `false` when disconnected.
  static Stream<bool> get bluetoothConnectionStream {
    return Stream.periodic(const Duration(seconds: 3))
        .asyncMap((_) async {
          try {
            final devices = FlutterBluePlus.connectedDevices;
            return devices.isNotEmpty;
          } catch (_) {
            return false;
          }
        })
        .distinct();
  }

  // ── Instance-based API for provider injection ─────────────────────────────

  bool _instanceBluetoothEnabled = false;
  bool _hasBluetoothAudio = false;
  bool get hasBluetoothAudio => _hasBluetoothAudio;

  StreamSubscription? _btConnectionSub;

  /// Start monitoring Bluetooth headset connections (instance method).
  void startBluetoothMonitoring() {
    if (_instanceBluetoothEnabled) return;
    _instanceBluetoothEnabled = true;
    _btConnectionSub?.cancel();
    _btConnectionSub = bluetoothConnectionStream.listen((connected) {
      _hasBluetoothAudio = connected;
    });
  }

  void stopBluetoothMonitoring() {
    _instanceBluetoothEnabled = false;
    _btConnectionSub?.cancel();
    _btConnectionSub = null;
    _hasBluetoothAudio = false;
  }

  /// Dispose all subscriptions.
  void dispose() {
    stopBluetoothMonitoring();
  }
}