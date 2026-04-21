import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio/player_service.dart';
import '../services/config/config_service.dart';
import '../theme/colors.dart';

class PlaybackControlsBar extends StatelessWidget {
  const PlaybackControlsBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.surface : AppColors.lightCard;
    final fgColor = isDark ? AppColors.textSecondary : AppColors.lightTextSecondary;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1.0,
          child: child,
        ),
      ),
      child: player.isPlaying
          ? Container(
              key: const ValueKey('bar'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _IconBtn(
                    icon: Icons.replay_rounded,
                    label: 'Replay',
                    color: fgColor,
                    onTap: () => context.read<PlayerService>().replayFromStart(),
                  ),
                  const SizedBox(width: 4),
                  const _Divider(),
                  const SizedBox(width: 4),
                  ...[0.75, 1.0, 1.25, 1.5].map((s) => _SpeedChip(
                        speed: s,
                        active: player.speed == s,
                        onTap: () {
                          context.read<PlayerService>().setSpeed(s);
                          context.read<ConfigService>().setPlaybackSpeed(s);
                        },
                      )),
                  const SizedBox(width: 4),
                  const _Divider(),
                  const SizedBox(width: 4),
                  _IconBtn(
                    icon: Icons.skip_next_rounded,
                    label: 'Skip',
                    color: fgColor,
                    onTap: () => context.read<PlayerService>().skipToNext(),
                  ),
                  const SizedBox(width: 2),
                  _IconBtn(
                    icon: player.isMuted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    label: player.isMuted ? 'Unmute' : 'Mute',
                    color: player.isMuted ? AppColors.error : fgColor,
                    onTap: () => context.read<PlayerService>().toggleMute(),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(key: ValueKey('empty')),
    );
  }
}

class _SpeedChip extends StatelessWidget {
  final double speed;
  final bool active;
  final VoidCallback onTap;

  const _SpeedChip({
    required this.speed,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = speed == 1.0 ? '1×' : '${speed}×';
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary.withValues(alpha: 0.85)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _IconBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      color: AppColors.textSecondary.withValues(alpha: 0.3),
    );
  }
}
