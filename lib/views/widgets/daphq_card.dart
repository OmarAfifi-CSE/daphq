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
      padding: EdgeInsets.all(15.0.rw(isDesktop)),
      decoration: BoxDecoration(
        color: AppColors.cardOverlay,
        borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}
