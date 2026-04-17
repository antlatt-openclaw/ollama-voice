import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/websocket_event.dart';
import '../services/storage/conversation_storage.dart';

class ConversationState extends ChangeNotifier {
  final ConversationStorage _storage;
  String? _activeConversationId;
  List<Message> _messages = [];
  List<Conversation> _conversations = [];

  String? get activeConversationId => _activeConversationId;
  List<Message> get messages => _messages;
  List<Conversation> get conversations => _conversations;

  String? get activeConversationName {
    if (_activeConversationId == null) return null;
    try {
      return _conversations
          .firstWhere((c) => c.id == _activeConversationId)
          .name;
    } on StateError {
      return null;
    }
  }

  ConversationState({required ConversationStorage storage})
      : _storage = storage {
    _loadConversations();
  }

  Future<void> _loadConversations() async {
    final data = await _storage.getRecentConversations();
    _conversations = data
        .map((row) => Conversation(
              id: row['id'] as String,
              name: row['name'] as String?,
              createdAt:
                  DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
              updatedAt:
                  DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
              lastMessage: row['last_message'] as String?,
            ))
        .toList();
    notifyListeners();
  }

  Future<String> startNewConversation() async {
    final id = await _storage.createConversation();
    _activeConversationId = id;
    _messages = [];
    final now = DateTime.now();
    _conversations.insert(
        0,
        Conversation(
          id: id,
          createdAt: now,
          updatedAt: now,
        ));
    notifyListeners();
    return id;
  }

  Future<void> addMessage(String role, String content) async {
    if (_activeConversationId == null) {
      await startNewConversation();
    }
    final convIdx = _conversations.indexWhere((c) => c.id == _activeConversationId);
    final isFirst = _messages.isEmpty && role == 'user' &&
        (convIdx < 0 || _conversations[convIdx].name == null);
    final msgId = const Uuid().v4();
    final now = DateTime.now();
    // Persist first — if save throws the UI stays consistent with storage.
    await _storage.addMessage(_activeConversationId!, role, content,
        id: msgId, timestamp: now);
    _messages.add(Message(
      id: msgId,
      conversationId: _activeConversationId!,
      role: role,
      content: content,
      timestamp: now,
    ));

    if (convIdx >= 0) {
      _conversations[convIdx].lastMessage = content;
      _conversations[convIdx].updatedAt = now;
    }

    notifyListeners();

    // Auto-name from first user message.
    if (isFirst) {
      final name = content.length > 50
          ? '${content.substring(0, 50)}…'
          : content;
      await _storage.updateConversationName(_activeConversationId!, name);
      final idx = _conversations.indexWhere((c) => c.id == _activeConversationId);
      if (idx >= 0) {
        _conversations[idx].name = name;
        notifyListeners();
      }
    }
  }

  Future<void> deleteMessage(String messageId) async {
    await _storage.deleteMessage(messageId);
    _messages.removeWhere((m) => m.id == messageId);
    final convIdx = _conversations.indexWhere((c) => c.id == _activeConversationId);
    if (convIdx >= 0) {
      _conversations[convIdx].lastMessage =
          _messages.isNotEmpty ? _messages.last.content : null;
    }
    notifyListeners();
  }

  Future<void> clearActiveConversation() async {
    if (_activeConversationId == null) return;
    await _storage.clearConversation(_activeConversationId!);
    _messages = [];
    final convIdx = _conversations.indexWhere((c) => c.id == _activeConversationId);
    if (convIdx >= 0) _conversations[convIdx].lastMessage = null;
    notifyListeners();
  }

  String exportAsText() {
    final buf = StringBuffer();
    for (final msg in _messages) {
      final label = msg.role == 'user' ? 'You' : 'Assistant';
      final time =
          '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
      buf.writeln('[$time] $label: ${msg.content}');
      buf.writeln();
    }
    return buf.toString().trim();
  }

  /// Returns the last N exchanges as an ordered history list for the LLM.
  List<Map<String, String>> recentHistory({int maxExchanges = 8}) {
    final result = <Map<String, String>>[];
    for (final msg in _messages) {
      result.add({'role': msg.role, 'content': msg.content});
    }
    // Keep last maxExchanges*2 messages (user+assistant pairs).
    if (result.length > maxExchanges * 2) {
      return result.sublist(result.length - maxExchanges * 2);
    }
    return result;
  }

  Future<void> loadConversation(String id) async {
    _activeConversationId = id;
    final data = await _storage.getMessages(id);
    _messages = data
        .map((row) => Message(
              id: row['id'] as String,
              conversationId: row['conversation_id'] as String,
              role: row['role'] as String,
              content: row['content'] as String,
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                  row['timestamp'] as int),
            ))
        .toList();
    notifyListeners();
  }

  Future<void> deleteConversation(String id) async {
    await _storage.deleteConversation(id);
    _conversations.removeWhere((c) => c.id == id);
    if (_activeConversationId == id) {
      _activeConversationId = null;
      _messages = [];
    }
    notifyListeners();
  }
}
