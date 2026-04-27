import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/config/config_service.dart';
import 'services/storage/conversation_storage.dart';
import 'services/notification_service.dart';
import 'providers/app_state.dart';
import 'providers/connection_state.dart' show VoiceConnectionState;
import 'providers/conversation_state.dart';
import 'providers/voice_controller.dart';
import 'services/audio/audio_coordinator.dart';
import 'services/audio/player_service.dart';
import 'services/audio/audio_mode_service.dart';
import 'services/audio/bluetooth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final configService = ConfigService();
  await configService.init();

  final conversationStorage = ConversationStorage();
  await conversationStorage.init();

  await NotificationService.init();

  final bluetoothService = BluetoothService();
  await bluetoothService.init();

  runApp(
    MultiProvider(
      providers: [
        Provider<ConfigService>.value(value: configService),
        Provider<ConversationStorage>(
          create: (_) => conversationStorage,
          dispose: (_, s) => s.close(),
        ),
        Provider<AudioModeService>(
          create: (_) => AudioModeService(),
          dispose: (_, s) => s.dispose(),
        ),
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(configService),
        ),
        ChangeNotifierProvider<VoiceConnectionState>(
          create: (_) => VoiceConnectionState(configService: configService),
        ),
        ChangeNotifierProvider<ConversationState>(
          create: (_) => ConversationState(storage: conversationStorage),
        ),
        ChangeNotifierProvider<AudioCoordinator>(
          create: (_) => AudioCoordinator(),
        ),
        ChangeNotifierProvider<PlayerService>(create: (_) => PlayerService()),
        Provider<BluetoothService>(
          create: (_) => bluetoothService,
          dispose: (_, s) => s.dispose(),
        ),
        // VoiceController depends on the providers above. lazy: false ensures
        // init() runs at app startup (subscribes to lifecycle + connection).
        ChangeNotifierProvider<VoiceController>(
          lazy: false,
          create: (ctx) => VoiceController(
            appState: ctx.read<AppState>(),
            connection: ctx.read<VoiceConnectionState>(),
            conversation: ctx.read<ConversationState>(),
            audio: ctx.read<AudioCoordinator>(),
            player: ctx.read<PlayerService>(),
            bluetooth: ctx.read<BluetoothService>(),
            config: configService,
          )..init(),
        ),
      ],
      child: const OpenClawVoiceApp(),
    ),
  );
}
