import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'providers/connection_state.dart' show VoiceConnectionState, ConnectionStatus;
import 'screens/onboarding_screen.dart';
import 'screens/main_screen.dart';
import 'theme/app_theme.dart';

class OpenClawVoiceApp extends StatelessWidget {
  const OpenClawVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return MaterialApp(
      title: 'OpenClaw Voice',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: appState.themeMode,
      home: const _AppShell(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class _AppShell extends StatelessWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final connState = context.watch<VoiceConnectionState>();

    if (!appState.isOnboarded) {
      return const OnboardingScreen();
    }

    if (connState.errorMessage != null &&
        connState.status == ConnectionStatus.disconnected) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Connection Failed',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  _friendlyError(connState.errorMessage!),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => connState.manualReconnect(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (connState.status == ConnectionStatus.connecting) {
      return const _ConnectingScreen();
    }

    return const MainScreen();
  }
}

String _friendlyError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('authentication failed') || lower.contains('auth')) {
    return 'Authentication failed. Check your token in Settings.';
  }
  if (lower.contains('timeout')) {
    return 'Connection timed out. Check your server URL and network.';
  }
  if (lower.contains('host lookup') || lower.contains('socketexception') || lower.contains('network')) {
    return 'Cannot reach the server. Check your network and server URL.';
  }
  return 'Could not connect to the server. Tap Retry to try again.';
}

class _ConnectingScreen extends StatelessWidget {
  const _ConnectingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Connecting to OpenClaw…'),
          ],
        ),
      ),
    );
  }
}
