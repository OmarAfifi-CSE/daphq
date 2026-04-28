import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/app_colors.dart';
import '../../core/responsive_utils.dart';

class DaphqCard extends StatelessWidget {
  final Widget child;
  final bool isDesktop;

  const DaphqCard({super.key, required this.child, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 15,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
          child: Container(
            padding: EdgeInsets.all(15.0.rw(isDesktop)),
            decoration: BoxDecoration(
              color: AppColors.cardOverlay,
              borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
              border: Border.all(color: AppColors.cardBorder, width: 1.0),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
