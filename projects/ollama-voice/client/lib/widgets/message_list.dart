import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import '../models/websocket_event.dart';
import '../providers/conversation_state.dart';
import '../theme/colors.dart';

class MessageList extends StatefulWidget {
  final List<Message> messages;
  final String currentTranscript;
  final String currentResponse;
  final bool isResponding;
  final double fontSize;
  final String searchQuery;
  final VoidCallback? onRegenerateLastResponse;
  final void Function(String text)? onReplayTts;

  const MessageList({
    super.key,
    required this.messages,
    required this.currentTranscript,
    required this.currentResponse,
    required this.isResponding,
    this.fontSize = 14.0,
    this.searchQuery = '',
    this.onRegenerateLastResponse,
    this.onReplayTts,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final Set<String> _timestampVisible = {};
  final ScrollController _scroll = ScrollController();
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final atBottom = _scroll.offset <= 60;
    if (atBottom != !_showScrollToBottom) {
      setState(() => _showScrollToBottom = !atBottom);
    }
  }

  void _toggleTimestamp(String id) {
    setState(() {
      if (_timestampVisible.contains(id)) {
        _timestampVisible.remove(id);
      } else {
        _timestampVisible.add(id);
      }
    });
  }

  // Filter + insert date separators.
  List<_ListItem> _buildItems() {
    final query = widget.searchQuery.toLowerCase();
    final filtered = query.isEmpty
        ? widget.messages
        : widget.messages
            .where((m) => m.content.toLowerCase().contains(query))
            .toList();

    final items = <_ListItem>[];
    DateTime? lastDate;
    for (final msg in filtered) {
      final msgDate = DateTime(
          msg.timestamp.year, msg.timestamp.month, msg.timestamp.day);
      if (lastDate == null || msgDate != lastDate) {
        items.add(_ListItem.dateSeparator(msgDate));
        lastDate = msgDate;
      }
      items.add(_ListItem.message(msg));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();
    final liveCount = _liveCount;

    if (items.isEmpty && liveCount == 0) return _buildEmptyState(context);

    final lastAssistantMsg = _lastAssistantMsg;

    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: items.length + liveCount,
          reverse: true,
          itemBuilder: (context, index) {
            // Live items at top (reverse order, so index 0 = most recent)
            if (index < liveCount) return _buildLiveItem(index);
            final item = items[items.length - 1 - (index - liveCount)];
            if (item.isDateSeparator) {
              return _DateSeparator(date: item.date!);
            }
            final msg = item.message!;
            final isLast = msg.id == lastAssistantMsg?.id &&
                msg.role == 'assistant';
            return _buildMessageItem(msg, showRegenerate: isLast);
          },
        ),

        // Scroll-to-bottom FAB
        if (_showScrollToBottom)
          Positioned(
            right: 16,
            bottom: 8,
            child: FloatingActionButton.small(
              heroTag: 'scrollBottom',
              backgroundColor: AppColors.primary,
              onPressed: () => _scroll.animateTo(
                0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              ),
              child: const Icon(Icons.arrow_downward, size: 18),
            ),
          ),
      ],
    );
  }

  int get _liveCount {
    int count = 0;
    if (widget.currentTranscript.isNotEmpty) count++;
    if (widget.isResponding || widget.currentResponse.isNotEmpty) count++;
    return count;
  }

  Message? get _lastAssistantMsg {
    for (int i = widget.messages.length - 1; i >= 0; i--) {
      if (widget.messages[i].role == 'assistant') return widget.messages[i];
    }
    return null;
  }

  Widget _buildLiveItem(int index) {
    if (index == 0 &&
        (widget.isResponding || widget.currentResponse.isNotEmpty)) {
      return _buildBubble(
        text: widget.currentResponse,
        isUser: false,
        isLive: true,
      );
    }
    if (widget.currentTranscript.isNotEmpty) {
      return _buildBubble(
          text: widget.currentTranscript, isUser: true, isLive: true);
    }
    return const SizedBox.shrink();
  }

  Widget _buildMessageItem(Message msg, {bool showRegenerate = false}) {
    final showTs = _timestampVisible.contains(msg.id);
    return Dismissible(
      key: Key(msg.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete_outline, color: AppColors.error),
      ),
      confirmDismiss: (direction) async {
        // Note: Dismissible + SnackBar undo is broken — the dismiss animation
        // completes visually before the user can tap undo, so the message
        // disappears but undo doesn't restore it. Using a simple confirm dialog
        // instead so the user decides before the animation runs.
        final shouldDelete = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete message?'),
            content: const Text('This message will be permanently removed.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Delete', style: TextStyle(color: AppColors.error)),
              ),
            ],
          ),
        );
        return shouldDelete ?? false;
      },
      onDismissed: (_) async {
        try {
          await context.read<ConversationState>().deleteMessage(msg.id);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to delete message')),
            );
          }
        }
      },
      child: GestureDetector(
        onTap: () => _toggleTimestamp(msg.id),
        onLongPress: () => _showMessageOptions(context, msg, showRegenerate),
        child: _buildBubble(
          text: msg.content,
          isUser: msg.role == 'user',
          timestamp: showTs ? msg.timestamp : null,
          isAssistant: msg.role == 'assistant',
          msgText: msg.content,
          showRegenerate: showRegenerate,
          showActions: showTs,
        ),
      ),
    );
  }

  Widget _buildBubble({
    required String text,
    required bool isUser,
    bool isLive = false,
    bool isAssistant = false,
    String? msgText,
    DateTime? timestamp,
    bool showRegenerate = false,
    bool showActions = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bubbleBg = isUser
        ? AppColors.primary.withValues(alpha: 0.2)
        : (isDark ? AppColors.surface : AppColors.lightCard);
    final textColor = isUser
        ? AppColors.primary
        : (isDark ? AppColors.textPrimary : AppColors.lightTextPrimary);
    final codeBlockBg = isDark
        ? const Color(0xFF0D0D14)
        : const Color(0xFFE8E8EE);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: bubbleBg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Content — typing dots when waiting, markdown for saved assistant, plain otherwise.
            if (isLive && !isUser && text.isEmpty)
              const _TypingDots()
            else if (isAssistant && !isLive)
              MarkdownBody(
                data: text,
                selectable: false,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                      color: textColor, fontSize: widget.fontSize, height: 1.4),
                  strong: TextStyle(
                      color: textColor,
                      fontSize: widget.fontSize,
                      fontWeight: FontWeight.bold),
                  em: TextStyle(
                      color: textColor,
                      fontSize: widget.fontSize,
                      fontStyle: FontStyle.italic),
                  code: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: widget.fontSize - 1,
                    color: textColor,
                    backgroundColor: codeBlockBg,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: codeBlockBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  codeblockPadding: const EdgeInsets.all(10),
                  listBullet: TextStyle(
                      color: textColor, fontSize: widget.fontSize),
                ),
              )
            else
              Text(
                text,
                style: TextStyle(color: textColor, fontSize: widget.fontSize),
              ),

            // Action row — only visible when message is tapped (showActions).
            if (isAssistant && !isLive && msgText != null && showActions) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Replay TTS
                  _BubbleAction(
                    icon: Icons.volume_up_outlined,
                    tooltip: 'Play aloud',
                    onTap: () => widget.onReplayTts?.call(msgText),
                  ),
                  const SizedBox(width: 4),
                  // Regenerate (only on last assistant message)
                  if (showRegenerate) ...[
                    _BubbleAction(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Regenerate',
                      onTap: () => widget.onRegenerateLastResponse?.call(),
                    ),
                    const SizedBox(width: 4),
                  ],
                  // Copy
                  _BubbleAction(
                    icon: Icons.copy_outlined,
                    tooltip: 'Copy',
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: msgText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],

            if (timestamp != null) ...[
              const SizedBox(height: 4),
              Text(
                _formatTime(timestamp),
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  void _showMessageOptions(
      BuildContext context, Message msg, bool showRegenerate) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: msg.content));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(seconds: 2)));
              },
            ),
            if (msg.role == 'assistant') ...[
              ListTile(
                leading: const Icon(Icons.volume_up_outlined),
                title: const Text('Play aloud'),
                onTap: () {
                  Navigator.pop(context);
                  widget.onReplayTts?.call(msg.content);
                },
              ),
              if (showRegenerate)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('Regenerate'),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onRegenerateLastResponse?.call();
                  },
                ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDark ? AppColors.textSecondary : AppColors.lightTextSecondary;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.mic_none_rounded,
            size: 64,
            color: textColor.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            'Start a conversation',
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Hold the button below to speak',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Supporting types ────────────────────────────────────────────────────────

class _ListItem {
  final Message? message;
  final DateTime? date;

  bool get isDateSeparator => date != null;

  const _ListItem.message(this.message) : date = null;
  const _ListItem.dateSeparator(DateTime d)
      : date = d,
        message = null;
}

// ── Date separator widget ───────────────────────────────────────────────────

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _label(date),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  String _label(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final target = DateTime(d.year, d.month, d.day);
    if (target == today) return 'Today';
    if (target == yesterday) return 'Yesterday';
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month]} ${d.day}${d.year != now.year ? ", ${d.year}" : ""}';
  }
}

// ── Bubble action icon ──────────────────────────────────────────────────────

class _BubbleAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _BubbleAction(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Icon(icon, size: 15, color: AppColors.textSecondary),
      ),
    );
  }
}

// ── Typing dots animation ───────────────────────────────────────────────────

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _dotOffset(int index) {
    final t = (_controller.value - index * 0.2) % 1.0;
    return -4.0 * math.sin(t * math.pi);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            3,
            (i) => Transform.translate(
              offset: Offset(0, _dotOffset(i)),
              child: Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
