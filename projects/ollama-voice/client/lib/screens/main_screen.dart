import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/websocket_event.dart';
import '../providers/app_state.dart' as app;
import '../providers/connection_state.dart' show VoiceConnectionState;
import '../providers/conversation_state.dart';
import '../providers/voice_controller.dart';
import '../services/audio/audio_coordinator.dart';
import '../services/audio/player_service.dart';
import '../services/config/config_service.dart';
import '../theme/colors.dart';
import '../widgets/push_to_talk_button.dart';
import '../widgets/connection_status.dart';
import '../widgets/message_list.dart';
import '../widgets/playback_controls.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // UI-only state — orchestration logic lives in VoiceController.
  bool _isTextInput = false;
  bool _isSearching = false;
  String _searchQuery = '';

  final TextEditingController _textController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyWakeLock();
    });
  }

  void _applyWakeLock() {
    final enabled = context.read<app.AppState>().wakeLockEnabled;
    enabled ? WakelockPlus.enable() : WakelockPlus.disable();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _textController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
  }

  void _sendCurrentText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    context.read<VoiceController>().sendTextMessage(text);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<app.AppState>();
    final connState = context.watch<VoiceConnectionState>();
    final convState = context.watch<ConversationState>();
    final player = context.watch<PlayerService>();
    final controller = context.watch<VoiceController>();

    return Scaffold(
      appBar: _buildAppBar(appState, convState),
      drawer: _ConversationDrawer(
        conversations: convState.conversations,
        activeId: convState.activeConversationId,
        onSelect: (id) async {
          await convState.loadConversation(id);
          if (mounted) Navigator.pop(context);
        },
        onNew: () async {
          await convState.startNewConversation();
          if (mounted) Navigator.pop(context);
        },
        onDelete: (id) => convState.deleteConversation(id),
      ),
      body: Column(
        children: [
          const ConnectionStatusBar(),

          if (appState.showDebugOverlay && appState.lastLatency != null)
            _LatencyOverlay(info: appState.lastLatency!),

          Expanded(
            child: MessageList(
              messages: convState.messages,
              currentTranscript: controller.currentTranscript,
              currentResponse: controller.currentResponse,
              isResponding: controller.isResponding,
              fontSize: appState.fontSize,
              searchQuery: _searchQuery,
              onRegenerateLastResponse: controller.regenerateLastResponse,
              onReplayTts: controller.replayTts,
            ),
          ),

          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: PlaybackControlsBar(),
          ),

          if (_isTextInput)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  12, 8, 8, MediaQuery.of(context).padding.bottom + 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      autofocus: true,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      onSubmitted: (_) => _sendCurrentText(),
                      enabled: connState.isConnected,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.send_rounded),
                    onPressed: connState.isConnected ? _sendCurrentText : null,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: EdgeInsets.fromLTRB(
                  24, 12, 24, MediaQuery.of(context).padding.bottom + 24),
              child: PushToTalkButton(
                isRecording: appState.isRecording,
                isPlaying: player.isPlaying,
                isConnected: connState.isConnected,
                tapToggleMode: appState.tapToggleMode,
                isHandsFreeMode: appState.handsFreeEnabled,
                isHandsFreeListening: appState.isHandsFreeListening,
                isResponding: controller.isResponding,
                isProcessing: controller.isProcessing,
                handsFreePhase: appState.handsFreePhase,
                wakeWordEnabled: appState.wakeWordEnabled,
                amplitudeStream: appState.isRecording
                    ? context.read<AudioCoordinator>().amplitudeStream
                    : null,
                recordingStartedAt: controller.recordingStartedAt,
                onPressed: controller.onPttPressed,
                onReleased: () => controller.onPttReleased(),
                onInterrupt: controller.interrupt,
              ),
            ),
        ],
      ),
    );
  }

  AppBar _buildAppBar(app.AppState appState, ConversationState convState) {
    if (_isSearching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _toggleSearch,
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search messages…',
            border: InputBorder.none,
          ),
          onChanged: (q) => setState(() => _searchQuery = q),
        ),
        actions: [
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() {
                _searchQuery = '';
                _searchController.clear();
              }),
            ),
        ],
      );
    }

    final convName = convState.activeConversationName;
    final agent = appState.activeAgent;
    final agentName = agent.isEmpty
        ? 'Default'
        : agent[0].toUpperCase() + agent.substring(1);
    return AppBar(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            convName ?? 'Ollama Voice',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          Text(
            agentName,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.secondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.add_comment_outlined),
          tooltip: 'New conversation',
          onPressed: () => convState.startNewConversation(),
        ),
        IconButton(
          icon: Icon(
              _isTextInput ? Icons.mic_none_rounded : Icons.keyboard_rounded),
          tooltip: _isTextInput ? 'Switch to voice' : 'Switch to text',
          onPressed: () => setState(() => _isTextInput = !_isTextInput),
        ),
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: _toggleSearch,
        ),
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () => _showSettings(context),
        ),
      ],
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, sc) => _SettingsSheet(scrollController: sc),
      ),
    );
  }
}

// ── Conversation drawer ──────────────────────────────────────────────────────

class _ConversationDrawer extends StatelessWidget {
  final List<Conversation> conversations;
  final String? activeId;
  final void Function(String id) onSelect;
  final VoidCallback onNew;
  final void Function(String id) onDelete;

  const _ConversationDrawer({
    required this.conversations,
    required this.activeId,
    required this.onSelect,
    required this.onNew,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Text('Conversations',
                      style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add_comment_outlined),
                    tooltip: 'New conversation',
                    onPressed: onNew,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: conversations.isEmpty
                  ? const Center(
                      child: Text('No conversations yet',
                          style: TextStyle(color: AppColors.textSecondary)))
                  : ListView.builder(
                      itemCount: conversations.length,
                      itemBuilder: (ctx, i) {
                        final conv = conversations[i];
                        final isActive = conv.id == activeId;
                        return Dismissible(
                          key: Key(conv.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            color: AppColors.error.withValues(alpha: 0.15),
                            child: const Icon(Icons.delete_outline,
                                color: AppColors.error),
                          ),
                          confirmDismiss: (_) async {
                            return await showDialog<bool>(
                              context: ctx,
                              builder: (d) => AlertDialog(
                                title: const Text('Delete conversation?'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(d, false),
                                      child: const Text('Cancel')),
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(d, true),
                                      child: const Text('Delete',
                                          style: TextStyle(
                                              color: AppColors.error))),
                                ],
                              ),
                            ) ??
                                false;
                          },
                          onDismissed: (_) => onDelete(conv.id),
                          child: ListTile(
                            selected: isActive,
                            selectedTileColor:
                                AppColors.primary.withValues(alpha: 0.12),
                            leading: const Icon(Icons.chat_bubble_outline,
                                size: 20),
                            title: Text(
                              conv.name ?? 'New conversation',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              conv.lastMessage != null
                                  ? '${conv.lastMessage!} · ${_relativeTime(conv.updatedAt)}'
                                  : _relativeTime(conv.updatedAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () => onSelect(conv.id),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }
}

// ── Latency overlay ──────────────────────────────────────────────────────────

class _LatencyOverlay extends StatelessWidget {
  final app.LatencyInfo info;
  const _LatencyOverlay({required this.info});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: Colors.black.withValues(alpha: 0.3),
      child: Text(
        'STT ${_ms(info.sttMs)}  •  LLM ${_ms(info.llmMs)}  •  TTS ${_ms(info.ttsMs)}',
        style: const TextStyle(
            color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'),
      ),
    );
  }

  String _ms(int? v) => v != null ? '${v}ms' : '—';
}

// ── Settings sheet ───────────────────────────────────────────────────────────

class _SettingsSheet extends StatelessWidget {
  final ScrollController scrollController;
  const _SettingsSheet({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<app.AppState>();
    final config = context.read<ConfigService>();
    final convState = context.read<ConversationState>();
    final conn = context.read<VoiceConnectionState>();

    return ListView(
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, MediaQuery.of(context).padding.bottom + 24),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),

        // ── CHAT ─────────────────────────────────────────────────────────
        _SectionHeader('CHAT'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            const Icon(Icons.format_size, size: 18),
            const SizedBox(width: 8),
            const Text('Font size'),
            const Spacer(),
            Text('${appState.fontSize.round()}px',
                style: const TextStyle(color: AppColors.textSecondary)),
          ]),
        ),
        Slider(
          value: appState.fontSize,
          min: 11,
          max: 22,
          divisions: 11,
          onChanged: (v) => appState.setFontSize(v),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.delete_outline),
          title: const Text('Clear Conversation'),
          onTap: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Clear conversation?'),
                content: const Text('All messages will be deleted.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Clear',
                          style: TextStyle(color: AppColors.error))),
                ],
              ),
            );
            if (ok == true && context.mounted) {
              await context.read<ConversationState>().clearActiveConversation();
              if (context.mounted) Navigator.pop(context);
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.ios_share_outlined),
          title: const Text('Export Conversation'),
          onTap: () {
            final text = convState.exportAsText();
            if (text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No messages to export')));
              return;
            }
            Share.share(text, subject: 'Ollama Voice Conversation');
          },
        ),

        const Divider(height: 24),

        // ── INPUT ─────────────────────────────────────────────────────────
        _SectionHeader('INPUT'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.hearing_rounded),
          title: const Text('Hands-free mode'),
          subtitle: const Text('Always listening — no button needed'),
          value: appState.handsFreeEnabled,
          onChanged: (v) async {
            await appState.setHandsFreeEnabled(v);
            if (context.mounted) {
              Navigator.pop(context);
              await conn.manualReconnect();
            }
          },
        ),

        // ── Wake Word ────────────────────────────────────────────────────
        if (appState.handsFreeEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.campaign_rounded),
            title: const Text('Wake word detection'),
            subtitle: const Text('Say "Hey Ollama" to start — off for privacy'),
            value: appState.wakeWordEnabled,
            onChanged: (v) => appState.setWakeWordEnabled(v),
          ),
          if (appState.wakeWordEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 56, bottom: 8),
              child: DropdownButtonFormField<String>(
                value: appState.wakeWordPhrase,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Wake phrase',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: const [
                  DropdownMenuItem(value: 'hey_ollama', child: Text('Hey Ollama')),
                  DropdownMenuItem(value: 'hey_kimi', child: Text('Hey Kimi')),
                  DropdownMenuItem(value: 'hey_beatrice', child: Text('Hey Beatrice')),
                  DropdownMenuItem(value: 'hey_computer', child: Text('Hey Computer')),
                ],
                onChanged: (v) {
                  if (v != null) appState.setWakeWordPhrase(v);
                },
              ),
            ),
        ],

        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.touch_app_outlined),
          title: const Text('Tap to toggle'),
          subtitle: const Text('Tap once to start, again to stop'),
          value: appState.tapToggleMode,
          onChanged: appState.handsFreeEnabled ? null : (v) => appState.setTapToggleMode(v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.headphones_outlined),
          title: const Text('Barge-in'),
          subtitle: const Text('Speak to interrupt response — use with headphones'),
          value: appState.bargeInEnabled,
          onChanged: appState.handsFreeEnabled
              ? (v) async {
                  await appState.setBargeInEnabled(v);
                  if (context.mounted) await conn.manualReconnect();
                }
              : null,
        ),

        if (appState.handsFreeEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.play_circle_outline),
            title: const Text('Auto-play responses'),
            subtitle: const Text('TTS plays automatically without tapping play'),
            value: appState.autoPlayEnabled,
            onChanged: (v) {
              appState.setAutoPlayEnabled(v);
              context.read<PlayerService>().setAutoPlay(v);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.graphic_eq),
            title: const Text('Client-side VAD'),
            subtitle: const Text('Detect speech start/stop locally to reduce latency'),
            value: appState.clientVadEnabled,
            onChanged: (v) => appState.setClientVadEnabled(v),
          ),
        ],

        const Divider(height: 24),

        // ── OUTPUT ────────────────────────────────────────────────────────
        _SectionHeader('OUTPUT'),

        if (appState.handsFreeEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.phone_in_talk_outlined),
            title: const Text('Proximity sensor'),
            subtitle: const Text('Switch to earpiece when phone is near ear'),
            value: appState.proximitySensorEnabled,
            onChanged: (v) => appState.setProximitySensorEnabled(v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.bluetooth_audio),
            title: const Text('Background listening'),
            subtitle: const Text('Listen for wake word when app is in background'),
            value: appState.backgroundListeningEnabled,
            onChanged: appState.wakeWordEnabled
                ? (v) => appState.setBackgroundListeningEnabled(v)
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.bluetooth_connected),
            title: const Text('Prefer Bluetooth'),
            subtitle: Text(
              appState.bluetoothConnected
                  ? 'Bluetooth headset connected'
                  : 'Route audio via Bluetooth when available',
              style: TextStyle(
                color: appState.bluetoothConnected
                    ? Colors.green
                    : AppColors.textSecondary,
              ),
            ),
            value: appState.bluetoothPreferred,
            onChanged: (v) => appState.setBluetoothPreferred(v),
          ),
        ],

        const Divider(height: 24),

        // ── AGENT ─────────────────────────────────────────────────────────
        _SectionHeader('AGENT'),
        ...ConfigService.availableAgents.map((agent) {
          final selected = appState.activeAgent == agent;
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: selected
                  ? AppColors.primary
                  : AppColors.primary.withValues(alpha: 0.12),
              child: Text(
                agent[0].toUpperCase(),
                style: TextStyle(
                  color: selected ? Colors.white : AppColors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(agent[0].toUpperCase() + agent.substring(1)),
            subtitle: Text(
              _agentDescriptions[agent] ?? '',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: selected
                ? const Icon(Icons.check_circle_rounded,
                    color: AppColors.primary, size: 20)
                : null,
            onTap: () async {
              await appState.setActiveAgent(agent);
              if (context.mounted) {
                Navigator.pop(context);
                await conn.manualReconnect();
              }
            },
          );
        }),

        const Divider(height: 24),

        // ── APPEARANCE ────────────────────────────────────────────────────
        _SectionHeader('APPEARANCE'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            const Icon(Icons.palette_outlined, size: 18),
            const SizedBox(width: 8),
            const Text('Theme'),
            const Spacer(),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode, size: 16),
                    label: Text('Dark')),
                ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode, size: 16),
                    label: Text('Light')),
                ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.phone_android, size: 16),
                    label: Text('Auto')),
              ],
              selected: {appState.themeMode},
              onSelectionChanged: (s) => appState.setThemeMode(s.first),
            ),
          ]),
        ),

        const Divider(height: 24),

        // ── POWER ─────────────────────────────────────────────────────────
        _SectionHeader('POWER'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.screen_lock_portrait_outlined),
          title: const Text('Keep screen on'),
          value: appState.wakeLockEnabled,
          onChanged: (v) {
            appState.setWakeLockEnabled(v);
            v ? WakelockPlus.enable() : WakelockPlus.disable();
          },
        ),

        const Divider(height: 24),

        // ── DEVELOPER ─────────────────────────────────────────────────────
        _SectionHeader('DEVELOPER'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.timer_outlined),
          title: const Text('Latency overlay'),
          subtitle: const Text('Show STT / LLM / TTS timing'),
          value: appState.showDebugOverlay,
          onChanged: (v) => appState.setShowDebugOverlay(v),
        ),

        const Divider(height: 24),

        // ── CONNECTION ────────────────────────────────────────────────────
        _SectionHeader('CONNECTION'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns),
          title: const Text('Server URL'),
          subtitle: Text(config.serverUrl,
              overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.edit_outlined, size: 16,
              color: AppColors.textSecondary),
          onTap: () async {
            final changed = await _showEditDialog(
              context,
              title: 'Server URL',
              initialValue: config.serverUrl,
              validator: _validateServerUrl,
            );
            if (changed != null && context.mounted) {
              await config.setServerUrl(changed);
              Navigator.pop(context);
              await conn.manualReconnect();
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.key),
          title: const Text('Auth Token'),
          subtitle: Text(config.hasAuthToken ? '••••••••' : 'Not set'),
          trailing: const Icon(Icons.edit_outlined, size: 16,
              color: AppColors.textSecondary),
          onTap: () async {
            final changed = await _showEditDialog(
              context,
              title: 'Auth Token',
              initialValue: config.authToken,
              obscured: true,
            );
            if (changed != null && context.mounted) {
              await config.setAuthToken(changed);
              Navigator.pop(context);
              await conn.manualReconnect();
            }
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.psychology),
          title: const Text('System Prompt'),
          subtitle: Text('Tap to customize AI personality',
              overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.edit_outlined, size: 16,
              color: AppColors.textSecondary),
          onTap: () async {
            final changed = await _showEditDialog(
              context,
              title: 'System Prompt',
              initialValue: config.systemPrompt,
              multiline: true,
            );
            if (changed != null && context.mounted) {
              // Save locally as cache
              await config.setSystemPrompt(changed);
              // Send to server for persistence (no reconnect needed)
              conn.sendSetConfig(systemPrompt: changed);
              Navigator.pop(context);
            }
          },
        ),
      ],
    );
  }
}

const _agentDescriptions = {
  'default': 'Uncensored Ollama model',
};

/// Returns null if `value` is a valid server URL, otherwise an error message.
String? _validateServerUrl(String value) {
  final v = value.trim();
  if (v.isEmpty) return 'URL cannot be empty';
  final uri = Uri.tryParse(v);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Not a valid URL';
  }
  const ok = {'ws', 'wss', 'http', 'https'};
  if (!ok.contains(uri.scheme)) {
    return 'URL must start with ws://, wss://, http://, or https://';
  }
  return null;
}

Future<String?> _showEditDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  bool obscured = false,
  bool multiline = false,
  String? Function(String value)? validator,
}) async {
  final controller = TextEditingController(text: initialValue);
  bool visible = !obscured;
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: !visible,
          autofocus: true,
          maxLines: multiline ? 8 : 1,
          decoration: InputDecoration(
            errorText: error,
            suffixIcon: obscured
                ? IconButton(
                    icon: Icon(
                        visible ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setS(() => visible = !visible),
                  )
                : null,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () {
                final input = controller.text.trim();
                final err = validator?.call(input);
                if (err != null) {
                  setS(() => error = err);
                  return;
                }
                Navigator.pop(ctx, input);
              },
              child: const Text('Save')),
        ],
      ),
    ),
  );
  controller.dispose();
  return (result != null && result.isNotEmpty) ? result : null;
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
