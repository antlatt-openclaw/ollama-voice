import 'package:flutter/material.dart';

class AppColors {
  // Primary
  static const Color primary = Color(0xFF6366F1);
  static const Color secondary = Color(0xFF8B5CF6);

  // Status
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);

  // Background (dark theme)
  static const Color background = Color(0xFF1A1B26);
  static const Color surface = Color(0xFF24283B);
  static const Color card = Color(0xFF292E42);

  // Text (dark theme)
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF9CA3AF);

  // Background (light theme)
  static const Color lightBackground = Color(0xFFF5F5F7);
  static const Color lightSurface = Color(0xFFEEEEF2);
  static const Color lightCard = Color(0xFFE2E2E8);

  // Text (light theme)
  static const Color lightTextPrimary = Color(0xFF1A1B26);
  static const Color lightTextSecondary = Color(0xFF6B7280);

  /// Returns the appropriate surface color based on current theme brightness.
  static Color surfaceFor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? surface : lightSurface;
  }

  static Color textPrimaryFor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? textPrimary : lightTextPrimary;
  }

  static Color textSecondaryFor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? textSecondary : lightTextSecondary;
  }

  static Color backgroundFor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? background : lightBackground;
  }
}