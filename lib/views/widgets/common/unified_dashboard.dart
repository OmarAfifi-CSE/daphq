import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import '../../../fabric/smart_link_evaluator.dart';
import 'daphq_card.dart';
import 'custom_snackbar.dart';
import 'orbital_radar.dart';
import 'trusted_devices_dialog.dart';

class UnifiedDashboard extends StatefulWidget {
  final bool isDesktop;

  const UnifiedDashboard({super.key, this.isDesktop = false});

  @override
  State<UnifiedDashboard> createState() => _UnifiedDashboardState();
}

class _UnifiedDashboardState extends State<UnifiedDashboard> {
  bool _isPickingFolder = false;

  String get _pickerLoadingText {
    if (!widget.isDesktop) {
      return "Opening Folder Picker...";
    }
    try {
      if (Platform.isWindows) return "Opening File Explorer...";
      if (Platform.isMacOS) return "Opening Finder...";
    } catch (_) {}
    return "Opening Folder Picker...";
  }

  Future<void> _handleReadinessAction(LocalRadioCapabilities? caps) async {
    final cubit = context.read<TransferCubit>();
    if (caps == null) {
      await cubit.refreshCapabilities();
      return;
    }
    if (!caps.wifiHardwarePresent) {
      if (mounted) {
        CustomSnackBar.show(
          context,
          message:
              'No Wi-Fi adapter detected. Transfers use your Ethernet LAN directly.',
        );
      }
      return;
    }
    if (caps.missingWifiPermission && Platform.isAndroid) {
      try {
        final sdkInt = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
        final Permission perm = sdkInt >= 33
            ? Permission.nearbyWifiDevices
            : Permission.locationWhenInUse;
        var status = await perm.status;
        if (!status.isGranted) {
          status = await perm.request();
        }
        if (status.isPermanentlyDenied) {
          await openAppSettings();
        }
      } catch (_) {}
      await cubit.refreshCapabilities();
      return;
    }
    if (!caps.wifiEnabled) {
      if (Platform.isWindows) {
        try {
          await launchUrl(Uri.parse('ms-settings:network-wifi'));
        } catch (_) {}
      } else if (mounted) {
        CustomSnackBar.show(
          context,
          message:
              'Turn on Wi-Fi in Quick Settings to enable Direct 5GHz speed.',
        );
      }
      await cubit.refreshCapabilities();
      return;
    }
    if (!caps.locationServiceEnabled) {
      if (Platform.isWindows) {
        try {
          await launchUrl(
            Uri.parse('ms-settings:privacy-location'),
            mode: LaunchMode.externalApplication,
          );
        } catch (_) {}
      }
      if (mounted) {
        CustomSnackBar.show(
          context,
          message: Platform.isWindows
              ? 'Enable Windows Location services (Settings > Privacy & security > Location) so Direct Wi-Fi discovery can scan.'
              : 'Turn on Location (GPS) so Direct 5GHz Wi-Fi discovery can start.',
        );
      }
      await cubit.refreshCapabilities();
      return;
    }
    await cubit.refreshCapabilities();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;
    final double scale = isDesktop ? context.desktopScale : 1.0;
    final cubit = context.read<TransferCubit>();

    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        return Column(
          key: const ValueKey('simple_mode_radar'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. TOP PANEL: Status capsule
              DaphqCard(
                isDesktop: isDesktop,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              SizedBox(
                                width: 24.rx(isDesktop, desktopScale: scale),
                                child: Center(
                                  child: _AnimatedStatusDot(
                                    isOnline: state.isReceiving,
                                    size: 10.rx(isDesktop, desktopScale: scale),
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 12.rw(isDesktop, desktopScale: scale),
                              ),
                              Expanded(
                                child: Text(
                                  _balanceText(
                                    state.isReceiving
                                        ? "Discoverable as "
                                        : "Offline (",
                                    state.isReceiving
                                        ? state.deviceName
                                        : "${state.deviceName})",
                                    threshold: isDesktop ? 45 : 25,
                                  ),
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 14.rx(
                                      isDesktop,
                                      desktopScale: scale,
                                    ),
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: 12.rw(isDesktop, desktopScale: scale)),
                        if (state.isLocatingFolder)
                          SizedBox(
                            width: 36.rw(isDesktop, desktopScale: scale),
                            height: 24.rh(isDesktop, desktopScale: scale),
                            child: const Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.primary,
                                ),
                              ),
                            ),
                          )
                        else
                          Switch.adaptive(
                            value: state.isReceiving,
                            activeThumbColor: Colors.white,
                            activeTrackColor: AppColors.primary.withAlpha(60),
                            inactiveThumbColor: AppColors.textMuted,
                            inactiveTrackColor: Colors.white.withAlpha(8),
                            onChanged: state.isTransferring
                                ? null
                                : (value) {
                                    if (value) {
                                      if (state.receiveFolder == null) {
                                        CustomSnackBar.show(
                                          context,
                                          message: AppConstants.selectFolderFirst,
                                        );
                                        return;
                                      }
                                      cubit.startReceiver();
                                    } else {
                                      cubit.stopReceiver();
                                    }
                                  },
                          ),
                      ],
                    ),
                    SizedBox(height: 10.rh(isDesktop, desktopScale: scale)),
                    Divider(color: Colors.white.withAlpha(10), height: 1),
                    SizedBox(height: 10.rh(isDesktop, desktopScale: scale)),
                    GestureDetector(
                      onTap: (state.isTransferring || _isPickingFolder)
                          ? null
                          : () {
                              setState(() {
                                _isPickingFolder = true;
                              });
                              WidgetsBinding.instance.addPostFrameCallback((
                                _,
                              ) async {
                                try {
                                  final String? path =
                                      await FilePicker.getDirectoryPath();
                                  if (path != null && mounted) {
                                    cubit.setReceiveFolder(path);
                                  }
                                } finally {
                                  if (Platform.isWindows ||
                                      Platform.isMacOS ||
                                      Platform.isLinux) {
                                    try {
                                      await windowManager.focus();
                                    } catch (_) {}
                                  }
                                  if (mounted) {
                                    setState(() {
                                      _isPickingFolder = false;
                                    });
                                  }
                                }
                              });
                            },
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 24.rx(isDesktop, desktopScale: scale),
                            child: Center(
                              child: _isPickingFolder
                                  ? SizedBox(
                                      width: 16.rx(
                                        isDesktop,
                                        desktopScale: scale,
                                      ),
                                      height: 16.rx(
                                        isDesktop,
                                        desktopScale: scale,
                                      ),
                                      child: const CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              AppColors.primary,
                                            ),
                                      ),
                                    )
                                  : Icon(
                                      Icons.folder_open_rounded,
                                      color: AppColors.primary,
                                      size: 16.rx(
                                        isDesktop,
                                        desktopScale: scale,
                                      ),
                                    ),
                            ),
                          ),
                          SizedBox(
                            width: 12.rw(isDesktop, desktopScale: scale),
                          ),
                          Expanded(
                            child: Text(
                              state.isLocatingFolder
                                  ? "Locating folder..."
                                  : _isPickingFolder
                                      ? _pickerLoadingText
                                      : (state.receiveFolder == null
                                            ? "Select download folder"
                                            : _balanceText(
                                                "Saving to: ",
                                                state.receiveFolder!,
                                                threshold: isDesktop ? 60 : 35,
                                              )),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _isPickingFolder
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
                                fontSize: 11.rx(isDesktop, desktopScale: scale),
                                fontWeight: _isPickingFolder
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          SizedBox(width: 8.rw(isDesktop, desktopScale: scale)),
                          Icon(
                            Icons.edit_outlined,
                            color: AppColors.primary,
                            size: 14.rx(isDesktop, desktopScale: scale),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Selection Banner
              if (state.selectedPaths.isNotEmpty && !state.isTransferring) ...[
                SizedBox(height: 12.rh(isDesktop, desktopScale: scale)),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 10.rw(isDesktop, desktopScale: scale),
                    vertical: 6.rh(isDesktop, desktopScale: scale),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(12),
                    borderRadius: BorderRadius.circular(
                      10.rr(isDesktop, desktopScale: scale),
                    ),
                    border: Border.all(color: AppColors.primary.withAlpha(30)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle_outline_rounded,
                        color: AppColors.primary,
                        size: 16.rx(isDesktop, desktopScale: scale),
                      ),
                      SizedBox(width: 8.rw(isDesktop, desktopScale: scale)),
                      Expanded(
                        child: Text(
                          "${state.selectedPaths.length} ${state.selectedPaths.length == 1 ? 'item' : 'items'} selected",
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12.rx(isDesktop, desktopScale: scale),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => cubit.clearSelection(),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8.rw(isDesktop, desktopScale: scale),
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          "Clear",
                          style: TextStyle(
                            color: AppColors.danger,
                            fontSize: 11.rx(isDesktop, desktopScale: scale),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // 1.5 FABRIC READINESS & SECURITY CONTROLS
              SizedBox(height: 12.rh(isDesktop, desktopScale: scale)),
              _FabricControlStrip(
                isDesktop: isDesktop,
                scale: scale,
                capabilities: state.localRadioCapabilities,
                trustedCount: state.trustedDevices.length,
                isDirectLinkConnecting: state.isDirectLinkConnecting,
                directLinkStatus: state.directLinkStatus,
                onTapReadiness: () =>
                    _handleReadinessAction(state.localRadioCapabilities),
                onOpenTrustedDevices: () =>
                    TrustedDevicesDialog.show(context, isDesktop: isDesktop),
              ),

              // 2. CENTER RADAR
              SizedBox(height: 20.rh(isDesktop, desktopScale: scale)),
              OrbitalRadar(isDesktop: isDesktop, size: 320.0 * scale),
              SizedBox(height: 28.rh(isDesktop, desktopScale: scale)),

              // 3. BOTTOM PANEL: Status bar with scan shimmer
              Center(
                child: _ScanStatusBar(
                  isReceiving: state.isReceiving,
                  isDesktop: isDesktop,
                ),
              ),
            ],
          );
      },
    );
  }

  String _balanceText(String prefix, String suffix, {int threshold = 30}) {
    final String fullText = "$prefix$suffix";
    if (fullText.length <= threshold) {
      return fullText;
    }

    final int center = fullText.length ~/ 2;
    int bestIndex = -1;
    int minDiff = fullText.length;

    for (int i = 0; i < fullText.length; i++) {
      final char = fullText[i];
      if (char == '/' || char == '\\' || char == ' ') {
        final int diff = (i - center).abs();
        if (diff < minDiff) {
          minDiff = diff;
          bestIndex = i;
        }
      }
    }

    if (bestIndex != -1 && minDiff < (fullText.length * 0.35)) {
      final char = fullText[bestIndex];
      if (char == '/' || char == '\\') {
        return "${fullText.substring(0, bestIndex + 1)}\n${fullText.substring(bestIndex + 1)}";
      } else {
        return "${fullText.substring(0, bestIndex)}\n${fullText.substring(bestIndex + 1)}";
      }
    }

    return "${fullText.substring(0, center)}\n${fullText.substring(center)}";
  }
}

/// Animated status dot that pulses when online.
class _AnimatedStatusDot extends StatefulWidget {
  final bool isOnline;
  final double size;

  const _AnimatedStatusDot({required this.isOnline, required this.size});

  @override
  State<_AnimatedStatusDot> createState() => _AnimatedStatusDotState();
}

class _AnimatedStatusDotState extends State<_AnimatedStatusDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.isOnline) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _AnimatedStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOnline && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isOnline && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final glowAlpha = widget.isOnline
            ? (60 + (_controller.value * 80)).toInt()
            : 0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.isOnline ? AppColors.success : AppColors.textMuted,
            boxShadow: widget.isOnline
                ? [
                    BoxShadow(
                      color: AppColors.success.withAlpha(glowAlpha),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
        );
      },
    );
  }
}

/// Bottom scan status bar with shimmer effect when scanning.
class _ScanStatusBar extends StatefulWidget {
  final bool isReceiving;
  final bool isDesktop;

  const _ScanStatusBar({
    required this.isReceiving,
    required this.isDesktop,
  });

  @override
  State<_ScanStatusBar> createState() => _ScanStatusBarState();
}

class _ScanStatusBarState extends State<_ScanStatusBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    if (widget.isReceiving) _shimmerController.repeat();
  }

  @override
  void didUpdateWidget(covariant _ScanStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isReceiving && !_shimmerController.isAnimating) {
      _shimmerController.repeat();
    } else if (!widget.isReceiving && _shimmerController.isAnimating) {
      _shimmerController.stop();
      _shimmerController.value = 0;
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;
    final scale = isDesktop ? context.desktopScale : 1.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(
        20.rr(isDesktop, desktopScale: scale),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: AnimatedBuilder(
          animation: _shimmerController,
          builder: (context, child) {
            return Container(
              padding: EdgeInsets.symmetric(
                horizontal: 16.rw(isDesktop, desktopScale: scale),
                vertical: 8.rh(isDesktop, desktopScale: scale),
              ),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(40),
                borderRadius: BorderRadius.circular(
                  20.rr(isDesktop, desktopScale: scale),
                ),
                border: Border.all(
                  color: Colors.white.withAlpha(10),
                  width: 1.0,
                ),
                gradient: widget.isReceiving
                    ? LinearGradient(
                        begin: Alignment(
                          -1.0 + 3.0 * _shimmerController.value,
                          0,
                        ),
                        end: Alignment(
                          -0.5 + 3.0 * _shimmerController.value,
                          0,
                        ),
                        colors: [
                          Colors.transparent,
                          AppColors.primary.withAlpha(8),
                          Colors.transparent,
                        ],
                      )
                    : null,
              ),
              child: child,
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 6.rx(isDesktop, desktopScale: scale),
                height: 6.rx(isDesktop, desktopScale: scale),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.isReceiving
                      ? AppColors.primary
                      : AppColors.textMuted,
                  boxShadow: widget.isReceiving
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(100),
                            blurRadius: 4.rr(
                              isDesktop,
                              desktopScale: scale,
                            ),
                            spreadRadius: 1.rr(
                              isDesktop,
                              desktopScale: scale,
                            ),
                          ),
                        ]
                      : null,
                ),
              ),
              SizedBox(width: 8.rw(isDesktop, desktopScale: scale)),
              Flexible(
                child: Text(
                  widget.isReceiving
                      ? "SCANNING FOR PEERS"
                      : "RADAR OFFLINE",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10.rx(isDesktop, desktopScale: scale),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FabricControlStrip extends StatelessWidget {
  final bool isDesktop;
  final double scale;
  final LocalRadioCapabilities? capabilities;
  final int trustedCount;
  final bool isDirectLinkConnecting;
  final String? directLinkStatus;
  final VoidCallback onTapReadiness;
  final VoidCallback onOpenTrustedDevices;

  const _FabricControlStrip({
    required this.isDesktop,
    required this.scale,
    required this.capabilities,
    required this.trustedCount,
    required this.isDirectLinkConnecting,
    required this.directLinkStatus,
    required this.onTapReadiness,
    required this.onOpenTrustedDevices,
  });

  ({IconData icon, String label, String tooltip, Color accent, bool highlighted})?
  _resolveActionableWarning(LocalRadioCapabilities? caps) {
    if (caps == null || !caps.wifiHardwarePresent) {
      return null;
    }
    const Color warningAmber = Color(0xFFF59E0B);
    if (caps.missingWifiPermission) {
      return (
        icon: Icons.security_rounded,
        label: 'Grant Wi-Fi Permission',
        tooltip:
            'Tap to grant Nearby Wi-Fi permission for direct Wi-Fi transfers.',
        accent: warningAmber,
        highlighted: true,
      );
    }
    if (!caps.wifiEnabled) {
      return (
        icon: Icons.wifi_off_rounded,
        label: 'Turn On Wi-Fi',
        tooltip: 'Wi-Fi is OFF. Turn Wi-Fi on for maximum direct speed.',
        accent: warningAmber,
        highlighted: true,
      );
    }
    if (!caps.locationServiceEnabled) {
      return (
        icon: Icons.location_off_rounded,
        label: 'Turn On Location',
        tooltip: 'Location service is required for direct Wi-Fi discovery.',
        accent: warningAmber,
        highlighted: true,
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final warning = _resolveActionableWarning(capabilities);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (isDirectLinkConnecting || directLinkStatus != null) ...[
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: 12.rw(isDesktop, desktopScale: scale),
              vertical: 6.rh(isDesktop, desktopScale: scale),
            ),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(24),
              borderRadius: BorderRadius.circular(
                20.rr(isDesktop, desktopScale: scale),
              ),
              border: Border.all(color: AppColors.primary.withAlpha(90)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isDirectLinkConnecting) ...[
                  SizedBox(
                    width: 12.rx(isDesktop, desktopScale: scale),
                    height: 12.rx(isDesktop, desktopScale: scale),
                    child: const CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: AppColors.primaryLight,
                    ),
                  ),
                  SizedBox(width: 8.rw(isDesktop, desktopScale: scale)),
                ] else ...[
                  Icon(
                    Icons.bolt_rounded,
                    size: 13.rx(isDesktop, desktopScale: scale),
                    color: AppColors.primaryLight,
                  ),
                  SizedBox(width: 6.rw(isDesktop, desktopScale: scale)),
                ],
                Flexible(
                  child: Text(
                    directLinkStatus ?? 'Establishing 5GHz Direct Link...',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.primaryLight,
                      fontSize: 11.rx(isDesktop, desktopScale: scale),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 10.rh(isDesktop, desktopScale: scale)),
        ],
        Wrap(
          spacing: 8.rw(isDesktop, desktopScale: scale),
          runSpacing: 8.rh(isDesktop, desktopScale: scale),
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (warning != null)
              Tooltip(
                message: warning.tooltip,
                child: _FabricActionChip(
                  isDesktop: isDesktop,
                  scale: scale,
                  icon: warning.icon,
                  label: warning.label,
                  accentColor: warning.accent,
                  highlighted: warning.highlighted,
                  onTap: onTapReadiness,
                ),
              ),
            _FabricActionChip(
              isDesktop: isDesktop,
              scale: scale,
              icon: Icons.verified_user_outlined,
              label: 'Trusted ($trustedCount)',
              accentColor:
                  trustedCount > 0 ? AppColors.success : AppColors.textSecondary,
              highlighted: trustedCount > 0,
              onTap: onOpenTrustedDevices,
            ),
          ],
        ),
      ],
    );
  }
}

class _FabricActionChip extends StatelessWidget {
  final bool isDesktop;
  final double scale;
  final IconData icon;
  final String label;
  final Color accentColor;
  final bool highlighted;
  final VoidCallback onTap;

  const _FabricActionChip({
    required this.isDesktop,
    required this.scale,
    required this.icon,
    required this.label,
    required this.accentColor,
    this.highlighted = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(
          10.rr(isDesktop, desktopScale: scale),
        ),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10.rw(isDesktop, desktopScale: scale),
            vertical: 6.rh(isDesktop, desktopScale: scale),
          ),
          decoration: BoxDecoration(
            color: highlighted
                ? accentColor.withAlpha(20)
                : AppColors.surfaceElevated.withAlpha(200),
            borderRadius: BorderRadius.circular(
              10.rr(isDesktop, desktopScale: scale),
            ),
            border: Border.all(
              color: highlighted
                  ? accentColor.withAlpha(90)
                  : Colors.white.withAlpha(14),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13.rx(isDesktop, desktopScale: scale),
                color: accentColor,
              ),
              SizedBox(width: 5.rw(isDesktop, desktopScale: scale)),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 10.5.rx(isDesktop, desktopScale: scale),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
