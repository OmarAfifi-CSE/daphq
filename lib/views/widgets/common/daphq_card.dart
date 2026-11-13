import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';

class DaphqCard extends StatelessWidget {
  final Widget child;
  final bool isDesktop;
  final Color? glowColor;

  const DaphqCard({
    super.key,
    required this.child,
    this.isDesktop = false,
    this.glowColor,
  });

  @override
  Widget build(BuildContext context) {
    final glow = glowColor ?? AppColors.primary;
    final double scale = isDesktop ? context.desktopScale : 1.0;

    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(
            18.0.rr(isDesktop, desktopScale: scale),
          ),
          boxShadow: [
            BoxShadow(
              color: glow.withAlpha(18),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            18.0.rr(isDesktop, desktopScale: scale),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0),
            child: Container(
              padding: EdgeInsets.all(14.0.rw(isDesktop, desktopScale: scale)),
              decoration: BoxDecoration(
                color: AppColors.cardOverlay,
                borderRadius: BorderRadius.circular(
                  18.0.rr(isDesktop, desktopScale: scale),
                ),
                border: Border.all(
                  color: Colors.white.withAlpha(14),
                  width: 1.0,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withAlpha(8),
                    Colors.transparent,
                    Colors.transparent,
                  ],
                ),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
