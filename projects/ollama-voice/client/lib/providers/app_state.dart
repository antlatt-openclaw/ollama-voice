import 'package:flutter/material.dart';
import '../services/config/config_service.dart';

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

  AppState(this._config) {
    _themeMode = _config.themeMode;
    _fontSize = _config.fontSize;
    _tapToggleMode = _config.tapToggleMode;
    _activeAgent = _config.activeAgent;
    _showDebugOverlay = _config.showDebugOverlay;
    _wakeLockEnabled = _config.wakeLockEnabled;
    _handsFreeEnabled = _config.handsFreeEnabled;
    _bargeInEnabled = _config.bargeInEnabled;
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
    notifyListeners();
  }

  void setLastLatency(LatencyInfo? info) {
    _lastLatency = info;
    notifyListeners();
  }
}
