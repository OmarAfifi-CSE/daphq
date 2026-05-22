import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Helper extensions to reduce repetitive `isDesktop ? X : X.sp` patterns.
///
/// Usage:
/// ```dart
/// fontSize: 16.0.rx(isDesktop, desktopScale: scale),  // responsive "x" — uses .sp on mobile
/// height: 20.0.rh(isDesktop, desktopScale: scale),    // responsive height — uses .h on mobile
/// width: 15.0.rw(isDesktop, desktopScale: scale),     // responsive width — uses .w on mobile
/// radius: 15.0.rr(isDesktop, desktopScale: scale),    // responsive radius — uses .r on mobile
/// ```
extension ResponsiveNum on num {
  /// Responsive font/icon size. Returns scaled value on desktop, `.sp` on mobile.
  double rx(bool isDesktop, {double desktopScale = 1.0}) =>
      isDesktop ? (toDouble() * desktopScale) : sp;

  /// Responsive height. Returns scaled value on desktop, `.h` on mobile.
  double rh(bool isDesktop, {double desktopScale = 1.0}) =>
      isDesktop ? (toDouble() * desktopScale) : h;

  /// Responsive width. Returns scaled value on desktop, `.w` on mobile.
  double rw(bool isDesktop, {double desktopScale = 1.0}) =>
      isDesktop ? (toDouble() * desktopScale) : w;

  /// Responsive radius. Returns scaled value on desktop, `.r` on mobile.
  double rr(bool isDesktop, {double desktopScale = 1.0}) =>
      isDesktop ? (toDouble() * desktopScale) : r;
}

extension ResponsiveContext on BuildContext {
  /// Calculates a smooth, dampened scale factor for desktop/windows screens
  /// when the window size exceeds the default size (1100x700).
  double get desktopScale {
    final size = MediaQuery.of(this).size;
    final w = size.width;
    final h = size.height;

    // Default design/starting dimensions of the window on desktop
    const defaultWidth = 1100.0;
    const defaultHeight = 700.0;

    if (w <= defaultWidth && h <= defaultHeight) return 1.0;

    final widthScale = w / defaultWidth;
    final heightScale = h / defaultHeight;

    // We use the smaller of the scale factors to make sure it fits perfectly
    // within the available window area in both directions.
    final rawScale = widthScale < heightScale ? widthScale : heightScale;

    // Dampen the scale so it doesn't grow too fast or look cartoonish
    final scale = 1.0 + (rawScale - 1.0) * 0.55;

    // Clamp the scale between 1.0 and 1.5 to maintain visual crispness
    return scale.clamp(1.0, 1.5);
  }
}
