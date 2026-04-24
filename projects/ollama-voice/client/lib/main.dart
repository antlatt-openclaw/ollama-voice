import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/config/config_service.dart';
import 'services/storage/conversation_storage.dart';
import 'services/notification_service.dart';
import 'providers/app_state.dart';
import 'providers/connection_state.dart' show VoiceConnectionState;
import 'providers/conversation_state.dart';
import 'services/audio/recorder_service.dart';
import 'services/audio/player_service.dart';
import 'services/audio/audio_mode_service.dart';
import 'services/audio/wake_word_service.dart';
import 'services/audio/bluetooth_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final configService = ConfigService();
  await configService.init();

  final conversationStorage = ConversationStorage();
  await conversationStorage.init();

  await NotificationService.init();

  final audioModeService = AudioModeService();

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
        Provider<AudioModeService>.value(value: audioModeService),
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(configService),
        ),
        ChangeNotifierProvider<VoiceConnectionState>(
          create: (_) => VoiceConnectionState(configService: configService),
        ),
        ChangeNotifierProvider<ConversationState>(
          create: (_) => ConversationState(storage: conversationStorage),
        ),
        Provider<RecorderService>(
          create: (_) => RecorderService(),
        ),
        ChangeNotifierProvider<PlayerService>(create: (_) => PlayerService()),
        ChangeNotifierProvider<WakeWordService>(
          create: (_) => WakeWordService(),
        ),
        Provider<BluetoothService>.value(value: bluetoothService),
      ],
      child: const OpenClawVoiceApp(),
    ),
  );
}
