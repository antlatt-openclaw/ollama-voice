import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/config/config_service.dart';
import '../providers/app_state.dart';
import '../theme/colors.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _isSaving = false;
  final _tokenController = TextEditingController();
  final _urlController = TextEditingController();
  String? _tokenError;
  String? _urlError;
  String? _permissionError;

  @override
  void initState() {
    super.initState();
    final config = context.read<ConfigService>();
    _urlController.text = config.serverUrl;
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _buildStep(),
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildWelcomeStep();
      case 1:
        return _buildPermissionStep();
      case 2:
        return _buildAuthStep();
      default:
        return _buildWelcomeStep();
    }
  }

  Widget _buildWelcomeStep() {
    return Column(
      key: const ValueKey('welcome'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.mic_rounded, size: 80, color: AppColors.primary),
        const SizedBox(height: 32),
        Text(
          'OpenClaw Voice',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          'Talk to your AI agents hands-free.\nHold to speak, release to listen.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: AppColors.textSecondary,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 48),
        FilledButton(
          onPressed: () => setState(() => _step = 1),
          child: const Text('Get Started'),
        ),
      ],
    );
  }

  Widget _buildPermissionStep() {
    return Column(
      key: const ValueKey('permission'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.record_voice_over, size: 64, color: AppColors.primary),
        const SizedBox(height: 32),
        Text(
          'Microphone Access',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          'OpenClaw Voice needs microphone access for voice input. '
          'Audio is only sent when you hold the push-to-talk button.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 48),
        FilledButton(
          onPressed: _requestPermission,
          child: const Text('Allow Microphone'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => setState(() => _step = 2),
          child: const Text('Skip for Now'),
        ),
        if (_permissionError != null) ...[
          const SizedBox(height: 12),
          Text(
            _permissionError!,
            style: const TextStyle(color: Colors.red, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Future<void> _requestPermission() async {
    final status = await Permission.microphone.request();
    if (status.isGranted || status.isLimited) {
      setState(() => _step = 2);
    } else {
      setState(() => _permissionError = 'Microphone permission denied. You can grant it later in Settings.');
    }
  }

  Widget _buildAuthStep() {
    return Column(
      key: const ValueKey('auth'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.key_rounded, size: 64, color: AppColors.primary),
        const SizedBox(height: 32),
        Text(
          'Connect to OpenClaw',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _urlController,
          decoration: InputDecoration(
            labelText: 'Server URL',
            border: const OutlineInputBorder(),
            errorText: _urlError,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _tokenController,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Auth Token',
            border: const OutlineInputBorder(),
            errorText: _tokenError,
          ),
        ),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: _isSaving ? null : _saveAndContinue,
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white),
                )
              : const Text('Connect'),
        ),
      ],
    );
  }

  Future<void> _saveAndContinue() async {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();

    setState(() { _urlError = null; _tokenError = null; });

    if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      setState(() => _urlError = 'URL must start with ws:// or wss://');
      return;
    }
    if (token.isEmpty) {
      setState(() => _tokenError = 'Token is required');
      return;
    }

    setState(() => _isSaving = true);
    try {
      final config = context.read<ConfigService>();
      await config.setServerUrl(url);
      await config.setAuthToken(token);
      if (!mounted) return;
      await context.read<AppState>().setOnboarded(true);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}