import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/responsive_utils.dart';

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
    with TickerProviderStateMixin {
  late AnimationController _pressController;
  late Animation<double> _scaleAnimation;
  late AnimationController _shimmerController;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.96,
    ).animate(CurvedAnimation(parent: _pressController, curve: Curves.easeInOut));
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _pressController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  bool get _isEnabled => widget.onPressed != null;

  void _onTapDown(TapDownDetails details) {
    if (_isEnabled) {
      _pressController.forward();
    }
  }

  void _onTapUp(TapUpDetails details) {
    if (_isEnabled) {
      _pressController.reverse();
      if (!widget.isDesktop) {
        HapticFeedback.lightImpact();
      }
      widget.onPressed!();
    }
  }

  void _onTapCancel() {
    if (_isEnabled) {
      _pressController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final double minHeight = 48.0.rh(widget.isDesktop);
    final double borderRadius = 14.0.rr(widget.isDesktop);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: _isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: _onTapDown,
        onTapUp: _onTapUp,
        onTapCancel: _onTapCancel,
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) {
            return Transform.scale(scale: _scaleAnimation.value, child: child);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            constraints: BoxConstraints(minHeight: minHeight),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: _isEnabled
                  ? LinearGradient(
                      colors: widget.gradientColors,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : LinearGradient(
                      colors: [Colors.white.withAlpha(10), Colors.white.withAlpha(6)],
                    ),
              boxShadow: _isEnabled
                  ? [
                      BoxShadow(
                        color: widget.gradientColors.first.withAlpha(
                          _isHovered ? 100 : 50,
                        ),
                        blurRadius: _isHovered ? 24 : 16,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: Stack(
                alignment: Alignment.center,
                fit: StackFit.passthrough,
                children: [
                  // Shimmer sweep overlay
                  if (_isEnabled && _isHovered)
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _shimmerController,
                        builder: (context, _) {
                          return ShaderMask(
                            shaderCallback: (bounds) {
                              return LinearGradient(
                                begin: Alignment(-1.0 + 3.0 * _shimmerController.value, 0),
                                end: Alignment(-0.5 + 3.0 * _shimmerController.value, 0),
                                colors: [
                                  Colors.transparent,
                                  Colors.white.withAlpha(25),
                                  Colors.transparent,
                                ],
                              ).createShader(bounds);
                            },
                            blendMode: BlendMode.srcATop,
                            child: Container(
                              color: Colors.white.withAlpha(15),
                            ),
                          );
                        },
                      ),
                    ),
                  // Child content perfectly centered with padding
                  Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: 8.rh(widget.isDesktop),
                      horizontal: 12.rw(widget.isDesktop),
                    ),
                    child: Center(
                      widthFactor: 1.0,
                      child: widget.child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
