import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../services/network/websocket_service.dart';
import '../services/config/config_service.dart';
import '../models/websocket_event.dart';

enum ConnectionStatus { disconnected, connecting, connected, reconnecting }

class VoiceConnectionState extends ChangeNotifier {
  final ConfigService _configService;
  WebSocketService? _wsService;
  StreamSubscription? _eventSub;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  String? _errorMessage;
  String? _connectionId;

  Timer? _reconnectTimer;
  StreamSubscription? _connectivitySub;
  int _retryCount = 0;
  static const int _maxRetries = 8;

  bool _hasNetwork = true;

  ConnectionStatus get status => _status;
  bool get isConnected => _status == ConnectionStatus.connected;
  bool get isConnecting => _status == ConnectionStatus.connecting ||
      _status == ConnectionStatus.reconnecting;
  String? get errorMessage => _errorMessage;
  String? get connectionId => _connectionId;
  bool get hasNetwork => _hasNetwork;

  Stream<Uint8List>? get audioStream => _wsService?.audioStream;
  // Event stream for UI
  Stream<WebSocketEvent>? get eventStream => _wsService?.events;

  VoiceConnectionState({required ConfigService configService})
      : _configService = configService {
    _initConnectivityListener();
    // Auto-connect on startup so the connecting screen shows before MainScreen.
    Future.microtask(connect);
  }

  void _initConnectivityListener() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      // connectivity_plus 5.x emits ConnectivityResult (single value).
      final hasConnection = result != ConnectivityResult.none;
      _hasNetwork = hasConnection;
      notifyListeners();
      if (hasConnection && _status == ConnectionStatus.disconnected) {
        print('[ConnectionState] Network restored, reconnecting...');
        _retryCount = 0;
        _reconnectTimer?.cancel();
        connect();
      }
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    if (_retryCount >= _maxRetries) {
      _errorMessage = 'Connection lost. Check your network and retry.';
      _setStatus(ConnectionStatus.disconnected);
      return;
    }
    final delaySeconds = min(pow(2, _retryCount).toInt(), 30);
    _retryCount++;
    print('[ConnectionState] Reconnect in ${delaySeconds}s (attempt $_retryCount/$_maxRetries)');
    _setStatus(ConnectionStatus.reconnecting);
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_status == ConnectionStatus.reconnecting) {
        connect();
      }
    });
  }

  Future<bool> connect() async {
    if (_status == ConnectionStatus.connected || _status == ConnectionStatus.connecting) {
      print('[ConnectionState] Already connected/connecting, returning true');
      return true;
    }

    print('[ConnectionState] Starting connection...');
    print('[ConnectionState] Server URL: ${_configService.serverUrl}');
    _setStatus(ConnectionStatus.connecting);
    _errorMessage = null;

    _wsService = WebSocketService(
      serverUrl: _configService.serverUrl,
      authToken: _configService.authToken,
      agent: _configService.activeAgent,
      mode: _configService.handsFreeEnabled ? 'hands_free' : 'ptt',
    );

    try {
      print('[ConnectionState] Calling WebSocketService.connect()...');
      final success = await _wsService!.connect();
      print('[ConnectionState] Connect result: $success');
      
      if (success) {
        _retryCount = 0;
        _connectionId = _wsService!.connectionId;
        _setStatus(ConnectionStatus.connected);
        _subscribeToEvents();
        // Sync system prompt from server
        _wsService!.sendGetConfig();
        print('[ConnectionState] Connection established!');
        return true;
      } else {
        _errorMessage = 'Authentication failed';
        await _wsService?.disconnect();
        _wsService = null;
        _setStatus(ConnectionStatus.disconnected);
        print('[ConnectionState] Connection failed: auth failed');
        return false;
      }
    } catch (e, stack) {
      _errorMessage = e.toString();
      await _wsService?.disconnect();
      _wsService = null;
      _setStatus(ConnectionStatus.disconnected);
      print('[ConnectionState] Connect error: $e');
      print('[ConnectionState] Stack: $stack');
      return false;
    }
  }

  /// Manual reconnect — resets retry counter and reconnects immediately.
  Future<void> manualReconnect() async {
    _reconnectTimer?.cancel();
    _retryCount = 0;
    _errorMessage = null;
    _eventSub?.cancel();
    await _wsService?.disconnect();
    _wsService = null;
    _connectionId = null;
    _setStatus(ConnectionStatus.disconnected);
    await connect();
  }

  Future<void> reconnectWithNewConnectionId() async {
    _reconnectTimer?.cancel();
    _eventSub?.cancel();
    await _wsService?.disconnect();
    _wsService = null;
    _connectionId = null;
    _retryCount = 0;
    _setStatus(ConnectionStatus.disconnected);
    await connect();
  }

  void _subscribeToEvents() {
    _eventSub?.cancel();
    _eventSub = _wsService?.events.listen((event) {
      switch (event.type) {
        case EventType.disconnected:
          // Unexpected drop (network loss, server restart, background kill)
          print('[ConnectionState] WebSocket dropped unexpectedly, scheduling reconnect');
          _eventSub?.cancel();
          final droppedService = _wsService;
          _wsService = null;
          _connectionId = null;
          _setStatus(ConnectionStatus.disconnected);
          droppedService?.disconnect();
          _scheduleReconnect();
          break;
        case EventType.connectionReplaced:
          // Another connection took over — reconnect with new ID
          reconnectWithNewConnectionId();
          break;
        case EventType.authFailed:
          _errorMessage = 'Authentication failed';
          _eventSub?.cancel();
          final failedService = _wsService;
          _wsService = null;
          _connectionId = null;
          _setStatus(ConnectionStatus.disconnected);
          failedService?.disconnect();
          _scheduleReconnect();
          break;
        case EventType.error:
          _errorMessage = event.data?['message'] as String? ?? 'Unknown error';
          notifyListeners();
          break;
        case EventType.config:
          // Server sent current config — update local cache
          final prompt = event.data?['system_prompt'] as String?;
          if (prompt != null) {
            _configService.setSystemPrompt(prompt);
          }
          notifyListeners();
          break;
        case EventType.configSaved:
          // Server confirmed prompt saved
          final prompt = event.data?['system_prompt'] as String?;
          if (prompt != null) {
            _configService.setSystemPrompt(prompt);
          }
          notifyListeners();
          break;
        case EventType.configReset:
          // Server confirmed reset to default
          final prompt = event.data?['system_prompt'] as String?;
          if (prompt != null) {
            _configService.setSystemPrompt(prompt);
          }
          notifyListeners();
          break;
        default:
          break;
      }
    });
  }

  void sendAudio(dynamic pcmData) {
    _wsService?.sendAudio(pcmData);
  }

  void sendInterrupt() {
    _wsService?.sendInterrupt();
  }

  void sendEndRecording({List<Map<String, String>>? history}) {
    _wsService?.sendEndRecording(history: history);
  }

  void sendTtsRequest(String text) {
    _wsService?.sendTtsRequest(text);
  }

  void sendTextQuery(String text, {List<Map<String, String>>? history}) {
    _wsService?.sendTextQuery(text, history: history);
  }

  void sendGetConfig() {
    _wsService?.sendGetConfig();
  }

  void sendSetConfig({String? systemPrompt}) {
    _wsService?.sendSetConfig(systemPrompt: systemPrompt);
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _retryCount = _maxRetries; // prevent auto-reconnect after explicit disconnect
    _eventSub?.cancel();
    await _wsService?.disconnect();
    _wsService = null;
    _connectionId = null;
    _setStatus(ConnectionStatus.disconnected);
  }

  void _setStatus(ConnectionStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _connectivitySub?.cancel();
    _eventSub?.cancel();
    // disconnect() is async — fire and handle errors to avoid unawaited futures
    _wsService?.disconnect().catchError((e) {
      print('[ConnectionState] Error during disconnect in dispose: $e');
    });
    super.dispose();
  }
}