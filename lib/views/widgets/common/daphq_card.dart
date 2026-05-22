import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';

class DaphqCard extends StatefulWidget {
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
  State<DaphqCard> createState() => _DaphqCardState();
}

class _DaphqCardState extends State<DaphqCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _borderController;

  @override
  void initState() {
    super.initState();
    _borderController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _borderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = widget.glowColor ?? AppColors.primary;
    final isDesktop = widget.isDesktop;
    final double scale = isDesktop ? context.desktopScale : 1.0;

    return AnimatedBuilder(
      animation: _borderController,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(
              18.0.rr(isDesktop, desktopScale: scale),
            ),
            boxShadow: [
              BoxShadow(
                color: glow.withAlpha(18),
                blurRadius: 24,
                offset: const Offset(0, 8),
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
                padding: EdgeInsets.all(
                  14.0.rw(isDesktop, desktopScale: scale),
                ),
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
                child: widget.child,
              ),
            ),
          ),
        );
      },
    );
  }
}
