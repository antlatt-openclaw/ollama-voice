import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:web_socket_channel/io.dart';
import 'package:uuid/uuid.dart';

import '../../models/websocket_event.dart';

class WebSocketService {
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final String serverUrl;
  final String authToken;
  String? _connectionId;

  StreamController<WebSocketEvent> _events = StreamController.broadcast();
  StreamController<Uint8List> _audioOut = StreamController.broadcast();

  Timer? _keepaliveTimer;
  static const Duration _keepaliveInterval = Duration(seconds: 25);
  bool _authenticated = false;

  String? get connectionId => _connectionId;
  Stream<WebSocketEvent> get events => _events.stream;
  Stream<Uint8List> get audioStream => _audioOut.stream;

  final String? agent;
  final String mode;
  final String? systemPrompt;

  WebSocketService({
    required this.serverUrl,
    required this.authToken,
    this.agent,
    this.mode = 'ptt',
    this.systemPrompt,
  });

  Future<bool> connect() async {
    // Recreate StreamControllers in case they were closed by a previous disconnect
    if (_events.isClosed) {
      _events = StreamController<WebSocketEvent>.broadcast();
    }
    if (_audioOut.isClosed) {
      _audioOut = StreamController<Uint8List>.broadcast();
    }

    // Cancel any previous subscription before creating a new channel.
    await _subscription?.cancel();
    _subscription = null;

    print('[WebSocket] Starting connect to: $serverUrl');
    final uri = Uri.parse(serverUrl);
    _connectionId = const Uuid().v4();
    print('[WebSocket] Connection ID: $_connectionId');

    try {
      // Use IOWebSocketChannel for native WebSocket on mobile
      print('[WebSocket] Attempting WebSocket.connect...');
      final socket = await WebSocket.connect(
        uri.toString(),
        protocols: ['openclaw-voice'],
      ).timeout(const Duration(seconds: 10), onTimeout: () {
        print('[WebSocket] Connection timeout!');
        throw TimeoutException('WebSocket connection timeout');
      });
      print('[WebSocket] WebSocket connected successfully');
      
      _channel = IOWebSocketChannel(socket);
      print('[WebSocket] IOWebSocketChannel created');

      final completer = Completer<bool>();

      _subscription = _channel!.stream.listen(
        (data) {
          print('[WebSocket] Received data: ${data is String ? data.substring(0, data.length > 100 ? 100 : data.length) : "binary"}');
          if (!completer.isCompleted) {
            if (data is String) {
              final event = WebSocketEvent.fromJson(jsonDecode(data));
              if (event.type == EventType.authOk) {
                print('[WebSocket] Auth OK received');
                _authenticated = true;
                completer.complete(true);
              } else {
                print('[WebSocket] Unexpected event: ${event.type}');
                completer.complete(false);
              }
              return; // auth message is not forwarded to _events
            }
          }
          _handleMessage(data);
        },
        onError: (error) {
          print('[WebSocket] Stream error: $error');
          if (!completer.isCompleted) {
            completer.complete(false);
          } else if (_authenticated && !_events.isClosed) {
            _events.add(WebSocketEvent(type: EventType.disconnected));
          }
        },
        onDone: () {
          print('[WebSocket] Stream done (connection closed)');
          if (!completer.isCompleted) {
            completer.complete(false);
          } else if (_authenticated && !_events.isClosed) {
            _events.add(WebSocketEvent(type: EventType.disconnected));
          }
        },
      );

      // Send auth as first message
      final authPayload = <String, dynamic>{
        'type': 'auth',
        'token': authToken,
        'connection_id': _connectionId,
        'mode': mode,
      };
      if (agent != null) authPayload['agent'] = agent;
      if (systemPrompt != null) authPayload['system_prompt'] = systemPrompt;
      final authMsg = jsonEncode(authPayload);
      print('[WebSocket] Sending auth message...');
      _channel!.sink.add(authMsg);
      print('[WebSocket] Auth sent, waiting for response...');

      final success = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print('[WebSocket] Auth response timeout');
          return false;
        },
      );

      print('[WebSocket] Auth result: $success');

      if (!success) {
        print('[WebSocket] Auth failed, closing connection');
        await _subscription?.cancel();
        _subscription = null;
        await _channel!.sink.close();
        _channel = null;
        return false;
      }

      _startKeepalive();
      print('[WebSocket] Connection established successfully');
      return true;
    } catch (e, stack) {
      print('[WebSocket] Connect error: $e');
      print('[WebSocket] Stack: $stack');
      return false;
    }
  }

  void _startKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(_keepaliveInterval, (_) {
      if (_channel != null) {
        _channel!.sink.add(jsonEncode({'type': 'ping'}));
      }
    });
  }

  void _handleMessage(dynamic data) {
    if (data is String) {
      final event = WebSocketEvent.fromJson(jsonDecode(data));
      if (event.type == EventType.pong) return;
      _events.add(event);
    } else if (data is List<int>) {
      _audioOut.add(data is Uint8List ? data : Uint8List.fromList(data));
    }
  }

  void sendAudio(dynamic pcmData) {
    if (pcmData is Uint8List) {
      print('[WebSocket] Sending audio: ${pcmData.length} bytes');
      _channel?.sink.add(pcmData);
    } else {
      print('[WebSocket] sendAudio got unexpected type: ${pcmData.runtimeType}');
    }
  }

  void sendInterrupt() {
    _channel?.sink.add(jsonEncode({
      'type': 'interrupt',
      'request_id': DateTime.now().millisecondsSinceEpoch.toString(),
    }));
  }

  void sendEndRecording({List<Map<String, String>>? history}) {
    final payload = <String, dynamic>{'type': 'end_recording'};
    if (history != null && history.isNotEmpty) {
      payload['history'] = history;
    }
    _channel?.sink.add(jsonEncode(payload));
  }

  void sendTtsRequest(String text) {
    _channel?.sink.add(jsonEncode({
      'type': 'tts_request',
      'text': text,
    }));
  }

  void sendTextQuery(String text, {List<Map<String, String>>? history}) {
    final payload = <String, dynamic>{
      'type': 'text_query',
      'text': text,
    };
    if (history != null && history.isNotEmpty) {
      payload['history'] = history;
    }
    _channel?.sink.add(jsonEncode(payload));
  }

  Future<void> disconnect() async {
    _keepaliveTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _subscription = null;
    _channel = null;
    if (!_events.isClosed) await _events.close();
    if (!_audioOut.isClosed) await _audioOut.close();
  }
}