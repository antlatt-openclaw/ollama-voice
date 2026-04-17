import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

class ConversationStorage {
  Database? _db;
  DateTime? _lastPruneTime;

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('ConversationStorage not initialized. Call init() first.');
    }
    return db;
  }

  Future<void> init() async {
    final path = join(await getDatabasesPath(), 'openclaw_voice.db');
    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            name TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_messages_conv ON messages(conversation_id)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
              'ALTER TABLE conversations ADD COLUMN name TEXT');
        }
      },
    );
    await pruneOldConversationsIfNeeded();
  }

  Future<String> createConversation() async {
    final id = const Uuid().v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _database.insert('conversations', {
      'id': id,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<void> updateConversationName(String id, String name) async {
    await _database.update(
      'conversations',
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> addMessage(
      String conversationId, String role, String content,
      {String? id, DateTime? timestamp}) async {
    final msgId = id ?? const Uuid().v4();
    final ts = (timestamp ?? DateTime.now()).millisecondsSinceEpoch;
    await _database.insert('messages', {
      'id': msgId,
      'conversation_id': conversationId,
      'role': role,
      'content': content,
      'timestamp': ts,
    });
    await _database.update(
      'conversations',
      {'updated_at': ts},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  Future<List<Map<String, dynamic>>> getMessages(
      String conversationId) async {
    return await _database.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getRecentConversations(
      {int limit = 50}) async {
    return await _database.rawQuery('''
      SELECT c.id, c.name, c.created_at, c.updated_at,
             (SELECT content FROM messages
              WHERE conversation_id = c.id
              ORDER BY timestamp DESC
              LIMIT 1) AS last_message
      FROM conversations c
      ORDER BY c.updated_at DESC
      LIMIT ?
    ''', [limit]);
  }

  Future<void> deleteMessage(String messageId) async {
    await _database.delete('messages', where: 'id = ?', whereArgs: [messageId]);
  }

  Future<void> clearConversation(String conversationId) async {
    await _database.delete('messages',
        where: 'conversation_id = ?', whereArgs: [conversationId]);
  }

  Future<void> deleteConversation(String id) async {
    await _database.transaction((txn) async {
      await txn.delete('messages',
          where: 'conversation_id = ?', whereArgs: [id]);
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Prune old conversations, but only once per day to avoid adding
  /// latency on every app start.
  Future<void> pruneOldConversationsIfNeeded({int keepCount = 50}) async {
    final now = DateTime.now();
    if (_lastPruneTime != null &&
        now.difference(_lastPruneTime!).inHours < 24) {
      return; // Pruned recently, skip
    }
    await pruneOldConversations(keepCount: keepCount);
    _lastPruneTime = now;
  }

  Future<void> pruneOldConversations({int keepCount = 50}) async {
    final toDelete = await _database.query(
      'conversations',
      columns: ['id'],
      orderBy: 'updated_at DESC',
      offset: keepCount,
    );
    if (toDelete.isEmpty) return;
    final ids = toDelete.map((r) => r['id'] as String).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    await _database.transaction((txn) async {
      await txn.delete('messages',
          where: 'conversation_id IN ($placeholders)', whereArgs: ids);
      await txn.delete('conversations',
          where: 'id IN ($placeholders)', whereArgs: ids);
    });
  }
}