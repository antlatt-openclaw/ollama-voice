import 'package:flutter/material.dart';
import '../services/config/config_service.dart';

/// Visual state for the hands-free conversation flow.
enum HandsFreePhase {
  /// Idle — waiting for wake word or user interaction.
  idle,

  /// Wake word listening — continuously listening for the wake word.
  wakeWordListening,

  /// Recording — VAD detected speech, user is actively speaking.
  recording,

  /// Processing — speech ended, waiting for server response.
  processing,

  /// Speaking — TTS audio is playing back.
  speaking,
}

class LatencyInfo {
  final int? sttMs;
  final int? llmMs;
  final int? ttsMs;
  const LatencyInfo({this.sttMs, this.llmMs, this.ttsMs});
}

class AppState extends ChangeNotifier {
  final ConfigService _config;

  bool _isRecording = false;
  late ThemeMode _themeMode;
  late double _fontSize;
  late bool _tapToggleMode;
  late String _activeAgent;
  late bool _showDebugOverlay;
  late bool _wakeLockEnabled;
  late bool _handsFreeEnabled;
  late bool _bargeInEnabled;
  bool _isHandsFreeListening = false;
  LatencyInfo? _lastLatency;

  // ── New hands-free state ─────────────────────────────────────────────────
  late bool _wakeWordEnabled;
  late String _wakeWordPhrase;
  late bool _autoPlayEnabled;
  late bool _proximitySensorEnabled;
  late bool _backgroundListeningEnabled;
  late bool _clientVadEnabled;
  late bool _bluetoothPreferred;
  bool _bluetoothConnected = false;
  HandsFreePhase _handsFreePhase = HandsFreePhase.idle;
  bool _isNearEar = false; // proximity sensor state

  AppState(this._config) {
    _themeMode = _config.themeMode;
    _fontSize = _config.fontSize;
    _tapToggleMode = _config.tapToggleMode;
    _activeAgent = _config.activeAgent;
    _showDebugOverlay = _config.showDebugOverlay;
    _wakeLockEnabled = _config.wakeLockEnabled;
    _handsFreeEnabled = _config.handsFreeEnabled;
    _bargeInEnabled = _config.bargeInEnabled;
    _wakeWordEnabled = _config.wakeWordEnabled;
    _wakeWordPhrase = _config.wakeWordPhrase;
    _autoPlayEnabled = _config.autoPlayEnabled;
    _proximitySensorEnabled = _config.proximitySensorEnabled;
    _clientVadEnabled = _config.clientVadEnabled;
    _bluetoothPreferred = _config.bluetoothPreferred;
    _backgroundListeningEnabled = _config.backgroundListeningEnabled;
  }

  bool get isOnboarded => _config.isOnboarded;
  bool get isRecording => _isRecording;
  ThemeMode get themeMode => _themeMode;
  double get fontSize => _fontSize;
  bool get tapToggleMode => _tapToggleMode;
  String get activeAgent => _activeAgent;
  bool get showDebugOverlay => _showDebugOverlay;
  bool get wakeLockEnabled => _wakeLockEnabled;
  bool get handsFreeEnabled => _handsFreeEnabled;
  bool get bargeInEnabled => _bargeInEnabled;
  bool get isHandsFreeListening => _isHandsFreeListening;
  LatencyInfo? get lastLatency => _lastLatency;

  // ── New getters ───────────────────────────────────────────────────────────
  bool get wakeWordEnabled => _wakeWordEnabled;
  String get wakeWordPhrase => _wakeWordPhrase;
  bool get autoPlayEnabled => _autoPlayEnabled;
  bool get proximitySensorEnabled => _proximitySensorEnabled;
  bool get backgroundListeningEnabled => _backgroundListeningEnabled;
  bool get clientVadEnabled => _clientVadEnabled;
  bool get bluetoothPreferred => _bluetoothPreferred;
  bool get bluetoothConnected => _bluetoothConnected;
  HandsFreePhase get handsFreePhase => _handsFreePhase;
  bool get isNearEar => _isNearEar;

  Future<void> setOnboarded(bool value) async {
    await _config.setOnboarded(value);
    notifyListeners();
  }

  void setRecording(bool value) {
    _isRecording = value;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _config.setThemeMode(mode);
    notifyListeners();
  }

  Future<void> setFontSize(double size) async {
    _fontSize = size;
    await _config.setFontSize(size);
    notifyListeners();
  }

  Future<void> setTapToggleMode(bool value) async {
    _tapToggleMode = value;
    await _config.setTapToggleMode(value);
    notifyListeners();
  }

  Future<void> setActiveAgent(String agent) async {
    _activeAgent = agent;
    await _config.setActiveAgent(agent);
    notifyListeners();
  }

  Future<void> setShowDebugOverlay(bool value) async {
    _showDebugOverlay = value;
    await _config.setShowDebugOverlay(value);
    notifyListeners();
  }

  Future<void> setWakeLockEnabled(bool value) async {
    _wakeLockEnabled = value;
    await _config.setWakeLockEnabled(value);
    notifyListeners();
  }

  Future<void> setHandsFreeEnabled(bool value) async {
    _handsFreeEnabled = value;
    await _config.setHandsFreeEnabled(value);
    notifyListeners();
  }

  Future<void> setBargeInEnabled(bool value) async {
    _bargeInEnabled = value;
    await _config.setBargeInEnabled(value);
    notifyListeners();
  }

  void setHandsFreeListening(bool value) {
    if (_isHandsFreeListening == value) return;
    _isHandsFreeListening = value;
    // Update the hands-free phase
    if (_handsFreeEnabled) {
      if (value) {
        _handsFreePhase = HandsFreePhase.recording;
      } else if (_handsFreePhase == HandsFreePhase.recording) {
        _handsFreePhase = HandsFreePhase.processing;
      }
    }
    notifyListeners();
  }

  void setLastLatency(LatencyInfo? info) {
    _lastLatency = info;
    notifyListeners();
  }

  // ── New setters ───────────────────────────────────────────────────────────

  Future<void> setWakeWordEnabled(bool value) async {
    _wakeWordEnabled = value;
    await _config.setWakeWordEnabled(value);
    notifyListeners();
  }

  Future<void> setWakeWordPhrase(String phrase) async {
    _wakeWordPhrase = phrase;
    await _config.setWakeWordPhrase(phrase);
    notifyListeners();
  }

  Future<void> setAutoPlayEnabled(bool value) async {
    _autoPlayEnabled = value;
    await _config.setAutoPlayEnabled(value);
    notifyListeners();
  }

  Future<void> setProximitySensorEnabled(bool value) async {
    _proximitySensorEnabled = value;
    await _config.setProximitySensorEnabled(value);
    notifyListeners();
  }

  Future<void> setBackgroundListeningEnabled(bool value) async {
    _backgroundListeningEnabled = value;
    await _config.setBackgroundListeningEnabled(value);
    notifyListeners();
  }

  Future<void> setClientVadEnabled(bool value) async {
    _clientVadEnabled = value;
    await _config.setClientVadEnabled(value);
    notifyListeners();
  }

  Future<void> setBluetoothPreferred(bool value) async {
    _bluetoothPreferred = value;
    await _config.setBluetoothPreferred(value);
    notifyListeners();
  }

  void setBluetoothConnected(bool value) {
    if (_bluetoothConnected == value) return;
    _bluetoothConnected = value;
    notifyListeners();
  }

  /// Set the hands-free conversation phase for visual feedback.
  void setHandsFreePhase(HandsFreePhase phase) {
    if (_handsFreePhase == phase) return;
    _handsFreePhase = phase;
    notifyListeners();
  }

  /// Update proximity sensor state (near ear = true).
  void setNearEar(bool value) {
    if (_isNearEar == value) return;
    _isNearEar = value;
    notifyListeners();
  }
}