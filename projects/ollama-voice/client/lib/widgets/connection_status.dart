import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/connection_state.dart' show VoiceConnectionState, ConnectionStatus;
import '../theme/colors.dart';

class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final connState = context.watch<VoiceConnectionState>();
    if (connState.status == ConnectionStatus.connected) return const SizedBox.shrink();
    final color = _getStatusColor(connState);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: color.withValues(alpha: 0.15),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              _getStatusText(connState),
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (connState.status == ConnectionStatus.disconnected) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => connState.manualReconnect(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.4),
                  ),
                ),
                child: const Text(
                  'Reconnect',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _getStatusColor(VoiceConnectionState state) {
    switch (state.status) {
      case ConnectionStatus.connected:
        return AppColors.success;
      case ConnectionStatus.connecting:
      case ConnectionStatus.reconnecting:
        return AppColors.warning;
      case ConnectionStatus.disconnected:
        return AppColors.error;
    }
  }

  String _getStatusText(VoiceConnectionState state) {
    switch (state.status) {
      case ConnectionStatus.connected:
        return 'Connected';
      case ConnectionStatus.connecting:
        return 'Connecting…';
      case ConnectionStatus.reconnecting:
        return 'Reconnecting…';
      case ConnectionStatus.disconnected:
        // Distinguish network loss from server unreachable.
        if (!state.hasNetwork) return 'No network connection';
        if (state.errorMessage != null) return 'Server unreachable';
        return 'Disconnected';
    }
  }
}
