import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Helper extensions to reduce repetitive `isDesktop ? X : X.sp` patterns.
///
/// Usage:
/// ```dart
/// fontSize: 16.0.rx(isDesktop),  // responsive "x" — uses .sp on mobile
/// height: 20.0.rh(isDesktop),    // responsive height — uses .h on mobile
/// width: 15.0.rw(isDesktop),     // responsive width — uses .w on mobile
/// radius: 15.0.rr(isDesktop),    // responsive radius — uses .r on mobile
/// ```
extension ResponsiveNum on num {
  /// Responsive font/icon size. Returns raw value on desktop, `.sp` on mobile.
  double rx(bool isDesktop) => isDesktop ? toDouble() : sp;

  /// Responsive height. Returns raw value on desktop, `.h` on mobile.
  double rh(bool isDesktop) => isDesktop ? toDouble() : h;

  /// Responsive width. Returns raw value on desktop, `.w` on mobile.
  double rw(bool isDesktop) => isDesktop ? toDouble() : w;

  /// Responsive radius. Returns raw value on desktop, `.r` on mobile.
  double rr(bool isDesktop) => isDesktop ? toDouble() : r;
}
