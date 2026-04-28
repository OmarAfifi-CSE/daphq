import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/responsive_utils.dart';

class AnimatedPressButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final List<Color> gradientColors;
  final bool isDesktop;

  const AnimatedPressButton({
    super.key,
    required this.child,
    this.onPressed,
    required this.gradientColors,
    this.isDesktop = false,
  });

  @override
  State<AnimatedPressButton> createState() => _AnimatedPressButtonState();
}

class _AnimatedPressButtonState extends State<AnimatedPressButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isEnabled => widget.onPressed != null;

  void _onTapDown(TapDownDetails details) {
    if (_isEnabled) {
      _controller.forward();
    }
  }

  void _onTapUp(TapUpDetails details) {
    if (_isEnabled) {
      _controller.reverse();
      if (!widget.isDesktop) {
        HapticFeedback.lightImpact();
      }
      widget.onPressed!();
    }
  }

  void _onTapCancel() {
    if (_isEnabled) {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final double height = 50.0.rh(widget.isDesktop);
    final double borderRadius = 15.0.rr(widget.isDesktop);

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: child,
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            gradient: _isEnabled
                ? LinearGradient(
                    colors: widget.gradientColors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : const LinearGradient(
                    colors: [Colors.white12, Colors.white12],
                  ),
            boxShadow: _isEnabled
                ? [
                    BoxShadow(
                      color: widget.gradientColors.first.withAlpha(76),
                      blurRadius: 15,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : [],
          ),
          child: Center(
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
