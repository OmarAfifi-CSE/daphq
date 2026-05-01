import 'package:flutter/material.dart';
import '../../core/responsive_utils.dart';

class SectionTitle extends StatelessWidget {
  final String title;
  final bool isDesktop;

  const SectionTitle({
    super.key,
    required this.title,
    required this.isDesktop,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        color: Colors.white,
        fontSize: 20.0.rx(isDesktop),
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
