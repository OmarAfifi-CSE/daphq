import 'package:flutter/material.dart';
import '../../core/responsive_utils.dart';

class StatusText extends StatelessWidget {
  final String text;
  final bool isError;
  final bool isDesktop;
  final String? tooltip;

  const StatusText({
    super.key,
    required this.text,
    this.isError = false,
    required this.isDesktop,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: isError ? Colors.redAccent : Colors.greenAccent,
      fontSize: 14.0.rx(isDesktop),
    );

    if (tooltip != null) {
      return Tooltip(
        message: tooltip!,
        child: Text(
          text,
          style: style,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    return Text(
      text,
      style: style,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
