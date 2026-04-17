import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/colors.dart';

class PushToTalkButton extends StatefulWidget {
  final bool isRecording;
  final bool isPlaying;
  final bool isConnected;
  final bool tapToggleMode;
  final bool isHandsFreeMode;
  final bool isHandsFreeListening;
  final bool isResponding;
  final bool isProcessing;
  final VoidCallback onPressed;
  final VoidCallback onReleased;
  final VoidCallback onInterrupt;
  final Stream<double>? amplitudeStream;
  final DateTime? recordingStartedAt;

  const PushToTalkButton({
    super.key,
    required this.isRecording,
    required this.isPlaying,
    required this.isConnected,
    required this.onPressed,
    required this.onReleased,
    required this.onInterrupt,
    this.tapToggleMode = false,
    this.isHandsFreeMode = false,
    this.isHandsFreeListening = false,
    this.isResponding = false,
    this.isProcessing = false,
    this.amplitudeStream,
    this.recordingStartedAt,
  });

  @override
  State<PushToTalkButton> createState() => _PushToTalkButtonState();
}

class _PushToTalkButtonState extends State<PushToTalkButton> {
  StreamSubscription<double>? _amplitudeSub;
  double _amplitude = 0.0;
  Timer? _timerTick;
  Duration _elapsed = Duration.zero;

  // Five bar multipliers — centre bar tallest.
  static const _barMult = [0.45, 0.70, 1.0, 0.70, 0.45];

  @override
  void initState() {
    super.initState();
    _subscribeAmplitude();
    _updateTimer();
  }

  @override
  void didUpdateWidget(PushToTalkButton old) {
    super.didUpdateWidget(old);
    if (old.amplitudeStream != widget.amplitudeStream) {
      _amplitudeSub?.cancel();
      _subscribeAmplitude();
    }
    _updateTimer();
  }

  void _subscribeAmplitude() {
    _amplitudeSub = widget.amplitudeStream?.listen((v) {
      if (mounted) setState(() => _amplitude = v);
    });
  }

  void _updateTimer() {
    if (widget.isRecording && widget.recordingStartedAt != null) {
      _timerTick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {
            _elapsed = DateTime.now().difference(widget.recordingStartedAt!);
          });
        }
      });
    } else {
      _timerTick?.cancel();
      _timerTick = null;
      if (_elapsed != Duration.zero) {
        setState(() => _elapsed = Duration.zero);
      }
    }
  }

  @override
  void dispose() {
    _amplitudeSub?.cancel();
    _timerTick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isPlaying || (widget.isHandsFreeMode && widget.isResponding)) {
      return _buildInterruptButton();
    }

    if (widget.isHandsFreeMode) {
      return _buildHandsFreeIndicator();
    }

    if (widget.isProcessing && !widget.isRecording) {
      return _buildProcessingIndicator();
    }

    final button = widget.tapToggleMode
        ? _buildTapToggleButton()
        : _buildHoldButton();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        if (widget.isRecording) ...[
          const SizedBox(height: 6),
          Text(
            _formatElapsed(_elapsed),
            style: const TextStyle(
              color: AppColors.error,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        if (!widget.isRecording && widget.tapToggleMode) ...[
          const SizedBox(height: 4),
          Text(
            'Tap to speak',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildHandsFreeIndicator() {
    final listening = widget.isHandsFreeListening;
    final processing = widget.isProcessing && !listening;

    final Color color;
    final double size;
    final double glowRadius;
    if (processing) {
      color = AppColors.warning;
      size = 72.0;
      glowRadius = 14.0;
    } else if (listening) {
      color = Colors.green;
      size = 88.0;
      glowRadius = 28.0;
    } else {
      color = AppColors.primary.withValues(alpha: 0.5);
      size = 72.0;
      glowRadius = 14.0;
    }

    final String label;
    final Color labelColor;
    if (processing) {
      label = 'Processing…';
      labelColor = AppColors.warning;
    } else if (listening) {
      label = 'Listening…';
      labelColor = Colors.green;
    } else {
      label = 'Hands-free';
      labelColor = AppColors.textSecondary;
    }

    Widget child;
    if (processing) {
      child = const Padding(
        padding: EdgeInsets.all(20),
        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
      );
    } else if (listening) {
      child = _buildWaveform();
    } else {
      child = Icon(Icons.hearing_rounded,
          color: Colors.white.withValues(alpha: 0.7), size: 30);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: listening ? 0.5 : 0.2),
                blurRadius: glowRadius,
                spreadRadius: listening ? 4 : 1,
              ),
            ],
          ),
          child: child,
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            label,
            key: ValueKey(label),
            style: TextStyle(
              color: labelColor,
              fontSize: 11,
              fontWeight: (listening || processing) ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProcessingIndicator() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.warning.withValues(alpha: 0.12),
            border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.4), width: 2),
          ),
          child: const Padding(
            padding: EdgeInsets.all(20),
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: AppColors.warning),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Processing…',
          style: TextStyle(
            color: AppColors.warning,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildInterruptButton() {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        widget.onInterrupt();
      },
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.error,
          boxShadow: [
            BoxShadow(
              color: AppColors.error.withValues(alpha: 0.4),
              blurRadius: 20,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(Icons.stop_rounded, color: Colors.white, size: 36),
      ),
    );
  }

  Widget _buildHoldButton() {
    return Listener(
      onPointerDown: (_) {
        HapticFeedback.mediumImpact();
        widget.onPressed();
      },
      onPointerUp: (_) {
        HapticFeedback.lightImpact();
        widget.onReleased();
      },
      onPointerCancel: (_) {
        widget.onReleased();
      },
      child: _buttonBody(),
    );
  }

  Widget _buildTapToggleButton() {
    return GestureDetector(
      onTap: () {
        if (widget.isRecording) {
          HapticFeedback.lightImpact();
          widget.onReleased();
        } else {
          HapticFeedback.mediumImpact();
          widget.onPressed();
        }
      },
      child: _buttonBody(),
    );
  }

  Widget _buttonBody() {
    final color = _getButtonColor();
    final size = widget.isRecording ? 88.0 : 80.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: widget.isRecording ? 30 : 16,
            spreadRadius: widget.isRecording ? 4 : 2,
          ),
        ],
      ),
      child: widget.isRecording
          ? _buildWaveform()
          : const Icon(Icons.mic_none_rounded, color: Colors.white, size: 36),
    );
  }

  Widget _buildWaveform() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (i) {
        final heightFraction = 0.15 + (_amplitude * 0.75) * _barMult[i];
        final barHeight = (88.0 * heightFraction).clamp(6.0, 40.0);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2.5),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: 4,
            height: barHeight,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }

  Color _getButtonColor() {
    if (!widget.isConnected) return AppColors.textSecondary;
    if (widget.isRecording) return AppColors.error;
    return AppColors.primary;
  }

  String _formatElapsed(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
