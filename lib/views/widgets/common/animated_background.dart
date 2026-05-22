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
  final Stopwatch _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    final math.Random rng = math.Random();

    // Stratified sampling (Jittered Grid) to guarantee a perfectly balanced,
    // uniform spread across the entire screen without any clumping or empty gaps.
    final int count = widget.particleCount;
    final int cols = math.sqrt(count * 1.6).round().clamp(1, count);
    final int rows = (count / cols).ceil();

    _particles = [];
    for (int i = 0; i < count; i++) {
      final int col = i % cols;
      final int row = i ~/ cols;

      final double cellWidth = 1.0 / cols;
      final double cellHeight = 1.0 / rows;

      // Place each particle in its designated cell with a random organic jitter offset
      final double x = (col + rng.nextDouble()) * cellWidth;
      final double y = (row + rng.nextDouble()) * cellHeight;

      _particles.add(
        _Particle(x: x.clamp(0.0, 1.0), y: y.clamp(0.0, 1.0), rng: rng),
      );
    }

    _stopwatch.start();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
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
                time: _stopwatch.elapsedMilliseconds / 10000.0,
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

  _Particle({required this.x, required this.y, required math.Random rng})
    : size = 0.5 + rng.nextDouble() * 1.5,
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

    // 1. Calculate positions of all particles first
    final List<Offset> positions = [];
    final List<double> opacities = [];
    final List<double> sizes = [];

    for (final p in particles) {
      final double t = time * p.speed;
      final double dx = math.sin(t * math.pi * 2 + p.phase) * 20;
      final double dy = math.cos(t * math.pi * 2 + p.phase * 1.3) * 15;

      final double px = (p.x * size.width + dx) % size.width;
      final double py =
          (p.y * size.height + dy + t * size.height * 0.05) % size.height;

      positions.add(Offset(px, py));
      opacities.add(p.opacity);
      sizes.add(p.size);
    }

    // 2. Draw neural network connection lines
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8; // Thin, delicate lines for an elegant, premium look

    const double maxDistance = 80.0; // Compact connection range

    for (int i = 0; i < positions.length; i++) {
      final posA = positions[i];
      for (int j = i + 1; j < positions.length; j++) {
        final posB = positions[j];

        // Optimize: skip calculation if bounding box dx or dy exceeds threshold
        final double dx = posA.dx - posB.dx;
        if (dx.abs() > maxDistance) continue;

        final double dy = posA.dy - posB.dy;
        if (dy.abs() > maxDistance) continue;

        final double distance = math.sqrt(dx * dx + dy * dy);
        if (distance < maxDistance) {
          final double opacityFactor = 1.0 - (distance / maxDistance);
          final double finalOpacity =
              opacityFactor * (opacities[i] + opacities[j]) * 0.22;

          if (finalOpacity > 0.01) {
            linePaint.color = AppColors.primaryLight.withAlpha(
              (finalOpacity * 255).toInt(),
            );
            canvas.drawLine(posA, posB, linePaint);
          }
        }
      }
    }

    // 3. Draw the particles (nodes) themselves on top of the lines
    for (int i = 0; i < positions.length; i++) {
      // Soft, premium opacity and slight size boost for perfect harmony
      final double particleOpacity = (opacities[i] * 1.1).clamp(0.0, 1.0);
      paint.color = AppColors.primaryLight.withAlpha(
        (particleOpacity * 255).toInt(),
      );
      canvas.drawCircle(positions[i], sizes[i] * 1.3, paint); // Elegant size
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) {
    return oldDelegate.time != time;
  }
}
