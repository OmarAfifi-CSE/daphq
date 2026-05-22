import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import '../common/custom_snackbar.dart';
import '../sender/device_transfer_menu.dart';

class OrbitalRadar extends StatefulWidget {
  final bool isDesktop;
  final double size;

  const OrbitalRadar({super.key, this.isDesktop = false, this.size = 250.0});

  @override
  State<OrbitalRadar> createState() => _OrbitalRadarState();
}

class _OrbitalRadarState extends State<OrbitalRadar>
    with TickerProviderStateMixin {
  late final AnimationController _rotationController;
  late final AnimationController _pulseController;
  final Stopwatch _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _stopwatch.start();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;
    final scale = isDesktop ? context.desktopScale : 1.0;
    final cubit = context.read<TransferCubit>();
    final double radarSize = widget.size;

    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        final devices = state.discoveredDevices;

        return Center(
          child: Container(
            width: radarSize.rx(isDesktop),
            height: radarSize.rx(isDesktop),
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.transparent,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 1. Radar paint: orbits, sweep, crosshairs, grid dots
                AnimatedBuilder(
                  animation: _rotationController,
                  builder: (context, child) {
                    return CustomPaint(
                      size: Size(
                        radarSize.rx(isDesktop),
                        radarSize.rx(isDesktop),
                      ),
                      painter: RadarSweepPainter(
                        angle: _rotationController.value * 2.0 * math.pi,
                        isScanning: true,
                        color: AppColors.primary,
                        scale: scale,
                      ),
                    );
                  },
                ),

                // 2. Cardinal direction labels
                ..._buildCardinalLabels(radarSize, isDesktop, scale),

                // 3. Central Pulse Halo — active only when receiving
                if (state.isReceiving)
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final double scaleVal =
                          1.0 + (_pulseController.value * 0.3);
                      final double opacity =
                          0.6 + (0.4 * (1.0 - _pulseController.value));
                      return Transform.scale(
                        scale: scaleVal,
                        child: Opacity(
                          opacity: opacity,
                          child: Container(
                            width: (radarSize * 0.33).rx(isDesktop),
                            height: (radarSize * 0.33).rx(isDesktop),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.primary.withAlpha(60),
                                width: 1.0,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                // Second outer pulse ring
                if (state.isReceiving)
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final double scaleVal =
                          1.0 + (_pulseController.value * 0.5);
                      final double opacity =
                          0.3 * (1.0 - _pulseController.value);
                      return Transform.scale(
                        scale: scaleVal,
                        child: Opacity(
                          opacity: opacity.clamp(0.0, 1.0),
                          child: Container(
                            width: (radarSize * 0.33).rx(isDesktop),
                            height: (radarSize * 0.33).rx(isDesktop),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.primary.withAlpha(30),
                                width: 0.8,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                // 4. Orbiting Devices
                ...List.generate(devices.length, (index) {
                  final device = devices[index];
                  final nodeWidth = 60.0.rx(isDesktop, desktopScale: scale);
                  final nodeHeight = 75.0.rx(isDesktop, desktopScale: scale);
                  final orbitRadius = (radarSize * 0.36).rx(isDesktop);

                  final String lowerName = device.name.toLowerCase();
                  final bool isLaptopDevice =
                      lowerName.contains("pc") ||
                      lowerName.contains("laptop") ||
                      lowerName.contains("desktop") ||
                      lowerName.contains("computer") ||
                      lowerName.contains("macbook") ||
                      lowerName.contains("imac") ||
                      lowerName.contains("windows") ||
                      lowerName.contains("linux") ||
                      lowerName.contains("mac-");

                  return AnimatedBuilder(
                    animation: _rotationController,
                    builder: (context, child) {
                      final double elapsedSeconds =
                          _stopwatch.elapsedMilliseconds / 1000.0;
                      // Slowly drift 360 degrees every 80 seconds
                      final double driftAngle =
                          (elapsedSeconds / 80.0) * 2.0 * math.pi;
                      // Use a stable, unique base angle for each device based on its IP address
                      // to prevent devices from jumping or rearranging when other devices are found
                      final double baseAngle = _getDeviceBaseAngle(device.ip);
                      final double angle = baseAngle + driftAngle;

                      final double bobbing =
                          math.sin(
                            elapsedSeconds * 2.0 * math.pi / 4.0 + index,
                          ) *
                          3.0.rx(isDesktop, desktopScale: scale);

                      final double x =
                          (orbitRadius + bobbing) * math.cos(angle);
                      final double y =
                          (orbitRadius + bobbing) * math.sin(angle);

                      return Positioned(
                        left:
                            (radarSize / 2).rx(isDesktop) + x - (nodeWidth / 2),
                        top:
                            (radarSize / 2).rx(isDesktop) +
                            y -
                            (nodeHeight / 2),
                        child: GestureDetector(
                          onTap: () => DeviceTransferMenu.show(
                            context,
                            device.ip,
                            device.name,
                            isDesktop,
                          ),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Container(
                              width: nodeWidth,
                              height: nodeHeight,
                              color: Colors.transparent,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Device node with glass-bubble effect
                                  Container(
                                    width: 44.rx(
                                      isDesktop,
                                      desktopScale: scale,
                                    ),
                                    height: 44.rx(
                                      isDesktop,
                                      desktopScale: scale,
                                    ),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        colors: [
                                          AppColors.primary.withAlpha(30),
                                          AppColors.primary.withAlpha(8),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.primary.withAlpha(
                                            25,
                                          ),
                                          blurRadius: 12.rr(
                                            isDesktop,
                                            desktopScale: scale,
                                          ),
                                          spreadRadius: 2.rr(
                                            isDesktop,
                                            desktopScale: scale,
                                          ),
                                        ),
                                      ],
                                      border: Border.all(
                                        color: AppColors.primary.withAlpha(70),
                                        width: 1.0,
                                      ),
                                    ),
                                    child: Center(
                                      child: SleekDeviceIcon(
                                        isLaptop: isLaptopDevice,
                                        color: AppColors.primaryLight.withAlpha(
                                          200,
                                        ),
                                        size: 18.rx(
                                          isDesktop,
                                          desktopScale: scale,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    height: 5.rh(
                                      isDesktop,
                                      desktopScale: scale,
                                    ),
                                  ),
                                  // Label Text
                                  Expanded(
                                    child: Text(
                                      device.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 10.rx(
                                          isDesktop,
                                          desktopScale: scale,
                                        ),
                                        fontWeight: FontWeight.w600,
                                        shadows: const [
                                          Shadow(
                                            color: Colors.black,
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                }),

                // 5. Central Node — glowing premium core
                GestureDetector(
                  onTap: () {
                    if (state.isReceiving) {
                      cubit.stopReceiver();
                    } else {
                      if (state.receiveFolder == null) {
                        CustomSnackBar.show(
                          context,
                          message: AppConstants.selectFolderFirst,
                        );
                        return;
                      }
                      cubit.startReceiver();
                    }
                  },
                  child: AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      final glowIntensity = state.isReceiving
                          ? 60 + (_pulseController.value * 30).toInt()
                          : 10;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: (radarSize * 0.28).rx(isDesktop),
                        height: (radarSize * 0.28).rx(isDesktop),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: state.isReceiving
                                ? [
                                    AppColors.primary.withAlpha(20),
                                    AppColors.primary.withAlpha(8),
                                  ]
                                : [
                                    Colors.white.withAlpha(8),
                                    Colors.white.withAlpha(3),
                                  ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: state.isReceiving
                                  ? AppColors.primary.withAlpha(glowIntensity)
                                  : AppColors.primary.withAlpha(10),
                              blurRadius: state.isReceiving ? 30 : 10,
                              spreadRadius: state.isReceiving ? 3 : 0,
                            ),
                          ],
                          border: Border.all(
                            color: state.isReceiving
                                ? AppColors.primary.withAlpha(180)
                                : Colors.white.withAlpha(20),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: SleekDeviceIcon(
                            isLaptop:
                                Platform.isWindows ||
                                Platform.isMacOS ||
                                Platform.isLinux,
                            color: state.isReceiving
                                ? AppColors.primary
                                : AppColors.textMuted,
                            size: (radarSize * 0.1).rx(isDesktop),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildCardinalLabels(
    double radarSize,
    bool isDesktop,
    double scale,
  ) {
    final labels = ['N', 'E', 'S', 'W'];
    final offsets = [
      Offset(0, -(radarSize * 0.48).rx(isDesktop)),
      Offset((radarSize * 0.48).rx(isDesktop), 0),
      Offset(0, (radarSize * 0.48).rx(isDesktop)),
      Offset(-(radarSize * 0.48).rx(isDesktop), 0),
    ];
    return List.generate(4, (i) {
      return Positioned(
        left:
            (radarSize / 2).rx(isDesktop) +
            offsets[i].dx -
            6.rw(isDesktop, desktopScale: scale),
        top:
            (radarSize / 2).rx(isDesktop) +
            offsets[i].dy -
            6.rh(isDesktop, desktopScale: scale),
        child: Text(
          labels[i],
          style: TextStyle(
            color: AppColors.textMuted.withAlpha(80),
            fontSize: 9.rx(isDesktop, desktopScale: scale),
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      );
    });
  }

  double _getDeviceBaseAngle(String input) {
    int hash = 0;
    for (int i = 0; i < input.length; i++) {
      hash = input.codeUnitAt(i) + ((hash << 5) - hash);
    }
    // Return a stable angle between 0 and 2*pi
    return (hash.abs() % 360) * math.pi / 180.0;
  }
}

class RadarSweepPainter extends CustomPainter {
  final double angle;
  final bool isScanning;
  final Color color;
  final double scale;

  RadarSweepPainter({
    required this.angle,
    required this.isScanning,
    required this.color,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    final double r1 = maxRadius * 0.28;
    final double r2 = maxRadius * 0.48;
    final double r3 = maxRadius * 0.72;
    final double r4 = maxRadius * 0.96;

    final paintRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // Concentric orbit rings with subtle glow
    canvas.drawCircle(center, r1, paintRing..color = color.withAlpha(18));
    canvas.drawCircle(center, r2, paintRing..color = color.withAlpha(12));
    canvas.drawCircle(center, r3, paintRing..color = color.withAlpha(7));
    canvas.drawCircle(center, r4, paintRing..color = color.withAlpha(3));

    // Crosshair lines
    final crosshairPaint = Paint()
      ..color = color.withAlpha(8)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(center.dx, center.dy - r4),
      Offset(center.dx, center.dy + r4),
      crosshairPaint,
    );
    canvas.drawLine(
      Offset(center.dx - r4, center.dy),
      Offset(center.dx + r4, center.dy),
      crosshairPaint,
    );

    // Grid dots at cardinal points on each ring
    final dotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withAlpha(25);
    for (final r in [r1, r2, r3, r4]) {
      for (int i = 0; i < 4; i++) {
        final a = i * math.pi / 2;
        canvas.drawCircle(
          Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a)),
          1.5 * scale,
          dotPaint,
        );
      }
    }

    // Sweeping sector
    if (isScanning) {
      final rect = Rect.fromCircle(center: center, radius: r4);
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          colors: [color.withAlpha(0), color.withAlpha(14)],
          stops: const [0.75, 1.0],
          transform: GradientRotation(angle),
        ).createShader(rect)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(center, r4, sweepPaint);

      // Leading edge line with glow
      final paintSweepLine = Paint()
        ..color = color.withAlpha(50)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;

      final double endX = center.dx + r4 * math.cos(angle);
      final double endY = center.dy + r4 * math.sin(angle);
      canvas.drawLine(center, Offset(endX, endY), paintSweepLine);

      // Particle trail behind sweep line (small dots fading out)
      for (int i = 1; i <= 5; i++) {
        final trailAngle = angle - (i * 0.08);
        final trailR = r4 * (0.3 + i * 0.13);
        final trailAlpha = (30 - i * 5).clamp(0, 255);
        final trailPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = color.withAlpha(trailAlpha);
        canvas.drawCircle(
          Offset(
            center.dx + trailR * math.cos(trailAngle),
            center.dy + trailR * math.sin(trailAngle),
          ),
          1.2 * scale,
          trailPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant RadarSweepPainter oldDelegate) {
    return oldDelegate.angle != angle ||
        oldDelegate.isScanning != isScanning ||
        oldDelegate.color != color ||
        oldDelegate.scale != scale;
  }
}

class SleekDeviceIcon extends StatelessWidget {
  final bool isLaptop;
  final Color color;
  final double size;

  const SleekDeviceIcon({
    super.key,
    required this.isLaptop,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    if (isLaptop) {
      return SizedBox(
        width: size * 1.35,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: size * 0.08,
              child: Container(
                width: size * 1.05,
                height: size * 0.65,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: color, width: 1.2),
                  color: color.withAlpha(10),
                ),
              ),
            ),
            Positioned(
              top: size * 0.14,
              child: Container(
                width: 1.5,
                height: 1.5,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ),
            Positioned(
              bottom: size * 0.12,
              child: Container(
                width: size * 1.32,
                height: 1.8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  color: color,
                  boxShadow: [
                    BoxShadow(color: color.withAlpha(60), blurRadius: 1.0),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: size * 0.56,
              height: size * 0.94,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: color, width: 1.2),
                color: color.withAlpha(10),
              ),
            ),
            Positioned(
              top: size * 0.12,
              child: Container(
                width: size * 0.14,
                height: 1.2,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(0.5),
                  color: color,
                ),
              ),
            ),
            Positioned(
              bottom: size * 0.08,
              child: Container(
                width: size * 0.22,
                height: 1.2,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(0.5),
                  color: color.withAlpha(80),
                ),
              ),
            ),
          ],
        ),
      );
    }
  }
}
