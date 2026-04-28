import 'package:flutter/material.dart';

/// Centralized color palette for the app.
class AppColors {
  AppColors._();

  /// Main scaffold background.
  static const Color background = Color(0xFF12122A);

  /// AppBar and window caption background.
  static const Color appBarBackground = Color(0xFF0F172A);

  /// Dialog background (e.g. auth dialog).
  static const Color dialogBackground = Color(0xFF252525);

  /// Card / container overlay for Glassmorphism.
  static Color cardOverlay = Colors.white.withAlpha(12);
  static Color cardBorder = Colors.white.withAlpha(25);

  /// Info card background and border.
  static Color infoBg = Colors.blue.withAlpha(25);
  static Color infoBorder = Colors.blue.withAlpha(50);

  /// Primary action color
  static const Color primary = Colors.blueAccent;
  
  /// Semantic colors
  static const Color success = Colors.green;
  static const Color danger = Colors.red;
}
