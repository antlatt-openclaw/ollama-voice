class Conversation {
  final String id;
  final DateTime createdAt;
  DateTime updatedAt;
  String? name;
  String? lastMessage;

  Conversation({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.name,
    this.lastMessage,
  });
}

class Message {
  final String id;
  final String conversationId;
  final String role; // 'user' or 'assistant'
  final String content;
  final DateTime timestamp;

  Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.timestamp,
  });
}

enum EventType {
  authOk,
  authFailed,
  ping,
  pong,
  connectionReplaced,
  disconnected,
  transcript,
  responseStart,
  responseDelta,
  audioStart,
  audioEnd,
  responseEnd,
  ttsOnlyStart,
  ttsOnlyEnd,
  listeningStart,
  listeningEnd,
  interruptAck,
  error,
  config,
  configSaved,
  configReset,
  unknown,
}

class WebSocketEvent {
  final EventType type;
  final Map<String, dynamic>? data;

  const WebSocketEvent({required this.type, this.data});

  factory WebSocketEvent.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? '';
    final typeMap = <String, EventType>{
      'auth_ok': EventType.authOk,
      'auth_failed': EventType.authFailed,
      'ping': EventType.ping,
      'pong': EventType.pong,
      'connection_replaced': EventType.connectionReplaced,
      'disconnected': EventType.disconnected,
      'transcript': EventType.transcript,
      'response_start': EventType.responseStart,
      'response_delta': EventType.responseDelta,
      'audio_start': EventType.audioStart,
      'audio_end': EventType.audioEnd,
      'response_end': EventType.responseEnd,
      'tts_only_start': EventType.ttsOnlyStart,
      'tts_only_end': EventType.ttsOnlyEnd,
      'listening_start': EventType.listeningStart,
      'listening_end': EventType.listeningEnd,
      'interrupt_ack': EventType.interruptAck,
      'error': EventType.error,
      'config': EventType.config,
      'config_saved': EventType.configSaved,
      'config_reset': EventType.configReset,
    };
    final data = Map<String, dynamic>.from(json)..remove('type');
    final resolvedType = typeMap[typeStr];
    if (resolvedType == null) {
      print('[WebSocketEvent] Unknown event type: "$typeStr"');
    }
    return WebSocketEvent(
      type: resolvedType ?? EventType.unknown,
      data: data.isEmpty ? null : data,
    );
  }
}

