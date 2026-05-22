import 'package:flutter/material.dart';

/// Centralized color palette for the app.
class AppColors {
  AppColors._();

  /// Main scaffold background.
  static const Color background = Color(0xFF0A0A1A);

  /// AppBar and window caption background.
  static const Color appBarBackground = Color(0xFF0D0D1F);

  /// Dialog background (e.g. auth dialog).
  static const Color dialogBackground = Color(0xFF161628);

  /// Card / container overlay for Glassmorphism.
  static Color cardOverlay = Colors.white.withAlpha(10);
  static Color cardBorder = Colors.white.withAlpha(20);

  /// Elevated surface (slightly brighter than card).
  static const Color surfaceElevated = Color(0xFF1E1E38);

  /// Info card background and border.
  static Color infoBg = Colors.blueAccent.withAlpha(20);
  static Color infoBorder = Colors.blueAccent.withAlpha(40);

  /// Primary action color — Blue
  static const Color primary = Colors.blueAccent;

  /// Primary light
  static const Color primaryLight = Color(0xFF64B5F6);

  /// Primary glow — for shadows/bloom effects
  static const Color primaryGlow = Colors.blueAccent;

  /// Shimmer color — for loading/scanning effects
  static const Color shimmer = Color(0xFF90CAF9);

  /// Semantic colors
  static const Color success = Color(0xFF34D399);
  static const Color successLight = Color(0xFF6EE7B7);
  static const Color danger = Color(0xFFFF6B6B);
  static const Color dangerLight = Color(0xFFFF9B9B);

  /// Typography colors
  static const Color textPrimary = Color(0xFFF0F0F5);
  static const Color textSecondary = Color(0xFFB0B0C8);
  static const Color textMuted = Color(0xFF6B6B8A);

  /// Snackbar background
  static const Color snackBarBackground = Color(0xFF1A1A2E);

  /// Discovery Status Colors
  static const Color discoverySuccess = Color(0xFF10B981);
  static const Color discoveryRecovering = Colors.blueAccent;
  static const Color discoveryFailed = Color(0xFFD97706);
  static const Color discoveryNoConnection = Color(0xFF475569);
}
