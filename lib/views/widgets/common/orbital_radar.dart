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
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void dispose() {
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;
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
                // 1. Sonar Sweep and Concentric Orbits Paint (Signature Daphq Primary Blue Accent)
                // Always scanning/spinning continuously to keep the radar alive!
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
                      ),
                    );
                  },
                ),

                // 2. Central Pulse Halo (Refined brand-blue ripple - active ONLY when receiving/discoverable!)
                if (state.isReceiving)
                  AnimatedBuilder(
                    animation: _rotationController,
                    builder: (context, child) {
                      final double scale =
                          1.0 + (_rotationController.value * 0.6);
                      final double opacity = (1.0 - _rotationController.value)
                          .clamp(0.0, 1.0);
                      return Transform.scale(
                        scale: scale,
                        child: Opacity(
                          opacity: opacity,
                          child: Container(
                            width: (radarSize * 0.36).rx(isDesktop),
                            height: (radarSize * 0.36).rx(isDesktop),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.primary.withAlpha(100),
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                // 3. Orbiting Devices (Pure glassmorphic Brand Blue satellites)
                ...List.generate(devices.length, (index) {
                  final device = devices[index];
                  final nodeWidth = 60.0.rx(isDesktop);
                  final nodeHeight = 75.0.rx(isDesktop);
                  final orbitRadius = (radarSize * 0.36).rx(isDesktop);

                  // Extremely robust check to prevent phones appearing as laptops on Windows
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
                      // Slow elegant orbit drift (15% of standard rotation speed)
                      final double driftAngle =
                          _rotationController.value * 0.15 * 2.0 * math.pi;
                      final double angle =
                          (index * 2.0 * math.pi / devices.length) + driftAngle;

                      // Bobbing weightlessness effect
                      final double bobbing =
                          math.sin(
                            _rotationController.value * 2.0 * math.pi * 3 +
                                index,
                          ) *
                          3.0.rx(isDesktop);

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
                          child: Container(
                            width: nodeWidth,
                            height: nodeHeight,
                            color: Colors.transparent,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Translucent glassmorphic planet node with glowing brand-blue device silhouette
                                Container(
                                  width: 42.rx(isDesktop),
                                  height: 42.rx(isDesktop),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [
                                        Colors.black54,
                                        AppColors.primary.withAlpha(20),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppColors.primary.withAlpha(20),
                                        blurRadius: 6,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                    border: Border.all(
                                      color: AppColors.primary.withAlpha(80),
                                      width: 1.0,
                                    ),
                                  ),
                                  child: Center(
                                    child: SleekDeviceIcon(
                                      isLaptop: isLaptopDevice,
                                      color: AppColors.primary.withAlpha(200),
                                      size: 18.rx(isDesktop),
                                    ),
                                  ),
                                ),
                                SizedBox(height: 5.rh(isDesktop)),
                                // Label Text
                                Expanded(
                                  child: Text(
                                    device.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 10.rx(isDesktop),
                                      fontWeight: FontWeight.bold,
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
                      );
                    },
                  );
                }),

                // 4. Central Node (Us! Styled like a glowing premium brand primary core)
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
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: (radarSize * 0.288).rx(isDesktop),
                    height: (radarSize * 0.288).rx(isDesktop),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: state.isReceiving
                            ? [Colors.black87, AppColors.primary.withAlpha(30)]
                            : [Colors.black87, Colors.white.withAlpha(10)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: state.isReceiving
                              ? AppColors.primary.withAlpha(80)
                              : AppColors.primary.withAlpha(15),
                          blurRadius: state.isReceiving ? 26 : 10,
                          spreadRadius: state.isReceiving ? 2 : 0,
                        ),
                      ],
                      border: Border.all(
                        color: state.isReceiving
                            ? AppColors.primary
                            : Colors.white24,
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
                            : Colors.white30,
                        size: (radarSize * 0.104).rx(isDesktop),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class RadarSweepPainter extends CustomPainter {
  final double angle;
  final bool isScanning;
  final Color color; // Orbits & Sweep color (AppColors.primary)

  RadarSweepPainter({
    required this.angle,
    required this.isScanning,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Precise concentric orbit bounds exactly matching the screenshot
    final double r1 = maxRadius * 0.28;
    final double r2 = maxRadius * 0.48;
    final double r3 = maxRadius * 0.72;
    final double r4 = maxRadius * 0.96;

    final paintRing = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Elegant Brand Blue orbits that fade out beautifully
    canvas.drawCircle(center, r1, paintRing..color = color.withAlpha(20));
    canvas.drawCircle(center, r2, paintRing..color = color.withAlpha(12));
    canvas.drawCircle(center, r3, paintRing..color = color.withAlpha(7));
    canvas.drawCircle(center, r4, paintRing..color = color.withAlpha(3));

    // Dynamic sweeping sector with elegant Brand Blue gradient (Always scanning to keep visual life!)
    if (isScanning) {
      final rect = Rect.fromCircle(center: center, radius: r4);
      final sweepPaint = Paint()
        ..shader = SweepGradient(
          colors: [
            color.withAlpha(0),
            color.withAlpha(16), // Beautiful glowing brand-blue sweep sector
          ],
          stops: const [0.75, 1.0],
          transform: GradientRotation(angle),
        ).createShader(rect)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(center, r4, sweepPaint);

      // The sweeping radial leading edge line (glowing primary brand blue)
      final paintSweepLine = Paint()
        ..color = color.withAlpha(65)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;

      final double endX = center.dx + r4 * math.cos(angle);
      final double endY = center.dy + r4 * math.sin(angle);
      canvas.drawLine(center, Offset(endX, endY), paintSweepLine);
    }
  }

  @override
  bool shouldRepaint(covariant RadarSweepPainter oldDelegate) {
    return oldDelegate.angle != angle ||
        oldDelegate.isScanning != isScanning ||
        oldDelegate.color != color;
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
      // Custom Sleek minimalist Laptop base + screen
      return SizedBox(
        width: size * 1.35,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Laptop screen bezel
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
            // Screen webcam dot
            Positioned(
              top: size * 0.14,
              child: Container(
                width: 1.5,
                height: 1.5,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ),
            // Laptop keyboard base line
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
      // Custom Sleek bezel-less Smartphone
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Phone body
            Container(
              width: size * 0.56,
              height: size * 0.94,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: color, width: 1.2),
                color: color.withAlpha(10),
              ),
            ),
            // Phone notch speaker line / punch hole
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
            // Phone bottom home bar indicator
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
