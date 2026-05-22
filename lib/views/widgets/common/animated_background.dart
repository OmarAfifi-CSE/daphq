import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';

/// A subtle floating particle field that creates cosmic depth.
/// Very lightweight — uses a single CustomPainter with simple math.
class AnimatedBackground extends StatefulWidget {
  final int particleCount;

  const AnimatedBackground({super.key, this.particleCount = 40});

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;
  final math.Random _rng = math.Random(42);
  final Stopwatch _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _particles = List.generate(widget.particleCount, (_) => _Particle(_rng));
    _stopwatch.start();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(
              painter: _ParticlePainter(
                particles: _particles,
                time: _stopwatch.elapsedMilliseconds / 20000.0,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),
    );
  }
}

class _Particle {
  final double x; // 0-1 normalized initial position
  final double y;
  final double size;
  final double speed;
  final double opacity;
  final double phase; // phase offset for unique drift pattern

  _Particle(math.Random rng)
    : x = rng.nextDouble(),
      y = rng.nextDouble(),
      size = 0.5 + rng.nextDouble() * 1.5,
      speed = 0.2 + rng.nextDouble() * 0.6,
      opacity = 0.15 + rng.nextDouble() * 0.35,
      phase = rng.nextDouble() * math.pi * 2;
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double time;

  _ParticlePainter({required this.particles, required this.time});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    // Subtle radial gradient overlay from center
    final centerGradient = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.8,
        colors: [AppColors.primary.withAlpha(6), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      centerGradient,
    );

    for (final p in particles) {
      final double t = time * p.speed;
      final double dx = math.sin(t * math.pi * 2 + p.phase) * 20;
      final double dy = math.cos(t * math.pi * 2 + p.phase * 1.3) * 15;

      final double px = (p.x * size.width + dx) % size.width;
      final double py =
          (p.y * size.height + dy + t * size.height * 0.05) % size.height;

      paint.color = AppColors.primaryLight.withAlpha((p.opacity * 255).toInt());
      canvas.drawCircle(Offset(px, py), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) {
    return oldDelegate.time != time;
  }
}
