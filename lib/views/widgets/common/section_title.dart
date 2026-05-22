import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';

class SectionTitle extends StatelessWidget {
  final String title;
  final bool isDesktop;

  const SectionTitle({super.key, required this.title, required this.isDesktop});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 20.0.rx(isDesktop),
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
    );
  }
}
