import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  static const String _serverUrlKey = 'server_url';
  static const String _authTokenKey = 'auth_token';
  static const String _themeModeKey = 'theme_mode';
  static const String _fontSizeKey = 'font_size';
  static const String _tapToggleModeKey = 'tap_toggle_mode';
  static const String _activeAgentKey = 'active_agent';
  static const String _showDebugOverlayKey = 'show_debug_overlay';
  static const String _wakeLockEnabledKey = 'wake_lock_enabled';
  static const String _handsFreeEnabledKey = 'hands_free_enabled';
  static const String _bargeInEnabledKey = 'barge_in_enabled';
  static const String _isOnboardedKey = 'is_onboarded';
  static const String _playbackSpeedKey = 'playback_speed';
  static const String _systemPromptKey = 'system_prompt';

  // ── New hands-free settings ───────────────────────────────────────────────
  static const String _wakeWordEnabledKey = 'wake_word_enabled';
  static const String _wakeWordPhraseKey = 'wake_word_phrase';
  static const String _autoPlayEnabledKey = 'auto_play_enabled';
  static const String _proximitySensorEnabledKey = 'proximity_sensor_enabled';
  static const String _backgroundListeningEnabledKey = 'background_listening_enabled';
  static const String _clientVadEnabledKey = 'client_vad_enabled';
  static const String _bluetoothPreferredKey = 'bluetooth_preferred';

  static const String _defaultServerUrl = 'wss://ollama-voice.antlatt.com/ws';
  static const String _defaultSystemPrompt = '''You are a helpful voice assistant. Keep responses short and conversational.''';

  static const List<String> availableAgents = [
    'default',
  ];

  late SharedPreferences _prefs;
  // Auth token lives in platform secure storage (Android Keystore / iOS Keychain).
  // We cache the loaded value so the getter can stay synchronous; SetAuthToken
  // writes through both the cache and storage.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  String? _cachedAuthToken;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadAuthToken();
  }

  Future<void> _loadAuthToken() async {
    try {
      _cachedAuthToken = await _secureStorage.read(key: _authTokenKey);
    } catch (e) {
      // Secure storage can fail (e.g. corrupted keystore on some Android upgrades).
      // Fall back to no token; user re-enters via Settings.
      debugPrint('[ConfigService] secure-storage read failed: $e');
      _cachedAuthToken = null;
    }

    // One-time migration: if the legacy SharedPreferences entry exists and we
    // haven't already loaded a value from secure storage, migrate it.
    final legacy = _prefs.getString(_authTokenKey);
    if (legacy != null && legacy.isNotEmpty && (_cachedAuthToken == null || _cachedAuthToken!.isEmpty)) {
      _cachedAuthToken = legacy;
      try {
        await _secureStorage.write(key: _authTokenKey, value: legacy);
        await _prefs.remove(_authTokenKey);
      } catch (e) {
        debugPrint('[ConfigService] secure-storage migrate failed: $e');
      }
    }
  }

  // ── Connection ───────────────────────────────────────────────────────────

  String get serverUrl => _prefs.getString(_serverUrlKey) ?? _defaultServerUrl;
  String get authToken => _cachedAuthToken ?? '';
  String get systemPrompt => _prefs.getString(_systemPromptKey) ?? _defaultSystemPrompt;
  bool get hasAuthToken => authToken.isNotEmpty;

  Future<void> setServerUrl(String url) => _prefs.setString(_serverUrlKey, url);

  Future<void> setAuthToken(String token) async {
    _cachedAuthToken = token;
    await _secureStorage.write(key: _authTokenKey, value: token);
    // Belt-and-suspenders: ensure no stale plaintext copy lingers.
    await _prefs.remove(_authTokenKey);
  }

  Future<void> setSystemPrompt(String prompt) => _prefs.setString(_systemPromptKey, prompt);

  // ── Appearance ───────────────────────────────────────────────────────────

  ThemeMode get themeMode {
    switch (_prefs.getString(_themeModeKey) ?? 'dark') {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.dark;
    }
  }

  double get fontSize => _prefs.getDouble(_fontSizeKey) ?? 14.0;

  Future<void> setThemeMode(ThemeMode mode) {
    final str = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.system
            ? 'system'
            : 'dark';
    return _prefs.setString(_themeModeKey, str);
  }

  Future<void> setFontSize(double size) => _prefs.setDouble(_fontSizeKey, size);

  // ── Input ────────────────────────────────────────────────────────────────

  bool get tapToggleMode => _prefs.getBool(_tapToggleModeKey) ?? false;
  Future<void> setTapToggleMode(bool value) => _prefs.setBool(_tapToggleModeKey, value);

  // ── Agent ────────────────────────────────────────────────────────────────

  String get activeAgent => _prefs.getString(_activeAgentKey) ?? 'default';
  Future<void> setActiveAgent(String agent) => _prefs.setString(_activeAgentKey, agent);

  // ── Developer ────────────────────────────────────────────────────────────

  bool get showDebugOverlay => _prefs.getBool(_showDebugOverlayKey) ?? false;
  Future<void> setShowDebugOverlay(bool value) => _prefs.setBool(_showDebugOverlayKey, value);

  // ── Power ────────────────────────────────────────────────────────────────

  bool get wakeLockEnabled => _prefs.getBool(_wakeLockEnabledKey) ?? false;
  Future<void> setWakeLockEnabled(bool value) => _prefs.setBool(_wakeLockEnabledKey, value);

  // ── Input mode ───────────────────────────────────────────────────────────

  bool get handsFreeEnabled => _prefs.getBool(_handsFreeEnabledKey) ?? false;
  Future<void> setHandsFreeEnabled(bool value) => _prefs.setBool(_handsFreeEnabledKey, value);

  // Barge-in disabled by default — requires headphones/earbuds for reliable AEC.
  bool get bargeInEnabled => _prefs.getBool(_bargeInEnabledKey) ?? false;
  Future<void> setBargeInEnabled(bool value) => _prefs.setBool(_bargeInEnabledKey, value);

  // ── Wake Word ─────────────────────────────────────────────────────────────

  /// Whether wake word detection is enabled. Default: false (off for privacy).
  bool get wakeWordEnabled => _prefs.getBool(_wakeWordEnabledKey) ?? false;
  Future<void> setWakeWordEnabled(bool value) => _prefs.setBool(_wakeWordEnabledKey, value);

  /// The wake word phrase to listen for. Default: "hey_ollama".
  String get wakeWordPhrase => _prefs.getString(_wakeWordPhraseKey) ?? 'hey_ollama';
  Future<void> setWakeWordPhrase(String phrase) => _prefs.setString(_wakeWordPhraseKey, phrase);

  // ── Auto-play ─────────────────────────────────────────────────────────────

  /// Whether TTS responses auto-play in hands-free mode. Default: true.
  bool get autoPlayEnabled => _prefs.getBool(_autoPlayEnabledKey) ?? true;
  Future<void> setAutoPlayEnabled(bool value) => _prefs.setBool(_autoPlayEnabledKey, value);

  // ── Proximity Sensor ──────────────────────────────────────────────────────

  /// Whether proximity sensor switches audio to earpiece. Default: false.
  bool get proximitySensorEnabled => _prefs.getBool(_proximitySensorEnabledKey) ?? false;
  Future<void> setProximitySensorEnabled(bool value) => _prefs.setBool(_proximitySensorEnabledKey, value);

  // ── Background Listening ──────────────────────────────────────────────────

  /// Whether the app continues listening for wake word when in background.
  /// Default: false (off for privacy and battery).
  bool get backgroundListeningEnabled => _prefs.getBool(_backgroundListeningEnabledKey) ?? false;
  Future<void> setBackgroundListeningEnabled(bool value) => _prefs.setBool(_backgroundListeningEnabledKey, value);

  // ── Client-side VAD ──────────────────────────────────────────────────────

  /// Whether client-side VAD is enabled in hands-free mode. Default: true.
  bool get clientVadEnabled => _prefs.getBool(_clientVadEnabledKey) ?? true;
  Future<void> setClientVadEnabled(bool value) => _prefs.setBool(_clientVadEnabledKey, value);

  // ── Bluetooth ──────────────────────────────────────────────────────────────

  /// Whether to prefer Bluetooth headset for audio I/O. Default: true.
  bool get bluetoothPreferred => _prefs.getBool(_bluetoothPreferredKey) ?? true;
  Future<void> setBluetoothPreferred(bool value) => _prefs.setBool(_bluetoothPreferredKey, value);

  // ── Onboarding ───────────────────────────────────────────────────────────

  bool get isOnboarded => _prefs.getBool(_isOnboardedKey) ?? false;
  Future<void> setOnboarded(bool value) => _prefs.setBool(_isOnboardedKey, value);

  // ── Playback ─────────────────────────────────────────────────────────────

  double get playbackSpeed => _prefs.getDouble(_playbackSpeedKey) ?? 1.0;
  Future<void> setPlaybackSpeed(double speed) => _prefs.setDouble(_playbackSpeedKey, speed);
}