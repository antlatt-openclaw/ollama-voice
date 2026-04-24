import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Bluetooth headset/earbud detection and audio routing.
class BluetoothService {
  final StreamController<bool> _connectionStream = StreamController.broadcast();
  StreamSubscription<List<ScanResult>>? _scanSub;
  bool _connected = false;
  bool get isConnected => _connected;
  Stream<bool> get connectionStream => _connectionStream.stream;

  Future<void> init() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _startScan();
      } else {
        _connected = false;
        if (!_connectionStream.isClosed) {
          _connectionStream.add(false);
        }
      }
    });

    if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on) {
      await _startScan();
    }
  }

  Future<void> _startScan() async {
    _scanSub?.cancel();
    // Listen for connected devices
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      bool hasAudioDevice = false;
      for (final result in results) {
        final name = result.device.advName.toLowerCase();
        // Heuristic: look for headset/earbud/headphone keywords
        if (name.contains('headset') ||
            name.contains('earbud') ||
            name.contains('headphone') ||
            name.contains('airpods') ||
            name.contains('buds') ||
            name.contains('pixel buds') ||
            name.contains('galaxy buds')) {
          hasAudioDevice = true;
        }
      }
      // Also check already-connected system devices
      if (!hasAudioDevice) {
        // For audio routing we rely on audio_session, but we still
        // report connection status for UI
        _checkConnectedDevices();
        return;
      }
      _updateConnected(true);
    });
    await FlutterBluePlus.startScan(
      withServices: [],
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> _checkConnectedDevices() async {
    try {
      final devices = FlutterBluePlus.connectedDevices;
      bool hasAudio = false;
      for (final device in devices) {
        final name = device.advName.toLowerCase();
        if (name.contains('headset') ||
            name.contains('earbud') ||
            name.contains('headphone') ||
            name.contains('airpods') ||
            name.contains('buds') ||
            name.contains('speaker')) {
          hasAudio = true;
        }
      }
      _updateConnected(hasAudio);
    } catch (_) {
      _updateConnected(false);
    }
  }

  void _updateConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!_connectionStream.isClosed) {
      _connectionStream.add(value);
    }
  }

  Future<void> dispose() async {
    _scanSub?.cancel();
    await FlutterBluePlus.stopScan();
    await _connectionStream.close();
  }
}
