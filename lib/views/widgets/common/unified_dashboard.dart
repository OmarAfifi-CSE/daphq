import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import 'daphq_card.dart';
import 'animated_press_button.dart';
import 'custom_snackbar.dart';
import 'orbital_radar.dart';
import '../sender/device_transfer_menu.dart';

class UnifiedDashboard extends StatefulWidget {
  final bool isDesktop;

  const UnifiedDashboard({super.key, this.isDesktop = false});

  @override
  State<UnifiedDashboard> createState() => _UnifiedDashboardState();
}

class _UnifiedDashboardState extends State<UnifiedDashboard> {
  late final TextEditingController _ipController;
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

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(
      text: context.read<TransferCubit>().state.targetIp,
    );
    _ipController.addListener(() {
      context.read<TransferCubit>().setTargetIp(_ipController.text);
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;
    final double scale = isDesktop ? context.desktopScale : 1.0;
    final cubit = context.read<TransferCubit>();

    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        return AnimatedCrossFade(
          duration: const Duration(milliseconds: 250),
          firstCurve: Curves.linear,
          secondCurve: Curves.linear,
          sizeCurve: Curves.linear,
          alignment: Alignment.topCenter,
          crossFadeState: state.isAdvancedMode
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: DaphqCard(
            key: const ValueKey('advanced_mode_card'),
            isDesktop: isDesktop,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Manual IP Transfer",
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15.rx(isDesktop, desktopScale: scale),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: AppColors.textMuted,
                        size: 20.rx(isDesktop, desktopScale: scale),
                      ),
                      onPressed: () => cubit.toggleAdvancedMode(),
                    ),
                  ],
                ),
                Divider(color: Colors.white.withAlpha(8), height: 16),
                SizedBox(height: 8.rh(isDesktop, desktopScale: scale)),
                TextField(
                  controller: _ipController,
                  cursorColor: AppColors.primary,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.0.rx(isDesktop, desktopScale: scale),
                  ),
                  decoration: InputDecoration(
                    labelText: AppConstants.receiverIpLabel,
                    labelStyle: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.0.rx(isDesktop, desktopScale: scale),
                    ),
                    helperText: AppConstants.receiverIpHelper,
                    helperStyle: TextStyle(
                      color: AppColors.textMuted.withAlpha(120),
                      fontSize: 10.0.rx(isDesktop, desktopScale: scale),
                    ),
                    filled: true,
                    fillColor: Colors.black.withAlpha(40),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        10.rr(isDesktop, desktopScale: scale),
                      ),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        10.rr(isDesktop, desktopScale: scale),
                      ),
                      borderSide: BorderSide(
                        color: AppColors.primary.withAlpha(80),
                        width: 1.0,
                      ),
                    ),
                    contentPadding: EdgeInsets.all(
                      12.rr(isDesktop, desktopScale: scale),
                    ),
                  ),
                  enabled: !state.isTransferring,
                ),
                SizedBox(height: 14.rh(isDesktop, desktopScale: scale)),
                AnimatedPressButton(
                  isDesktop: isDesktop,
                  onPressed: () {
                    final ip = _ipController.text.trim();
                    if (ip.isEmpty) {
                      CustomSnackBar.show(
                        context,
                        message: AppConstants.enterTargetIp,
                      );
                      return;
                    }
                    DeviceTransferMenu.show(
                      context,
                      ip,
                      "Manual Receiver",
                      isDesktop,
                    );
                  },
                  gradientColors: const [
                    AppColors.primary,
                    AppColors.primaryLight,
                  ],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.open_in_new_rounded,
                        color: Colors.white,
                        size: 16.rx(isDesktop, desktopScale: scale),
                      ),
                      SizedBox(width: 6.rw(isDesktop, desktopScale: scale)),
                      Text(
                        "Select Content & Send",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13.rx(isDesktop, desktopScale: scale),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          secondChild: Column(
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
                                    await windowManager.focus();
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
                          "${state.selectedPaths.length} items selected",
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

              // 2. CENTER RADAR
              SizedBox(height: 35.rh(isDesktop, desktopScale: scale)),
              OrbitalRadar(isDesktop: isDesktop, size: 320.0 * scale),
              SizedBox(height: 35.rh(isDesktop, desktopScale: scale)),

              // 3. BOTTOM PANEL: Status bar with scan shimmer
              Center(
                child: _ScanStatusBar(
                  isReceiving: state.isReceiving,
                  isDesktop: isDesktop,
                  onManualIpTap: () => cubit.toggleAdvancedMode(),
                ),
              ),
            ],
          ),
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
  final VoidCallback onManualIpTap;

  const _ScanStatusBar({
    required this.isReceiving,
    required this.isDesktop,
    required this.onManualIpTap,
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
          child: !isDesktop
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
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
                        Text(
                          widget.isReceiving
                              ? "SCANNING FOR PEERS"
                              : "RADAR OFFLINE",
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 10.rx(isDesktop, desktopScale: scale),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8.rh(isDesktop, desktopScale: scale)),
                    Container(
                      width: 80.rw(isDesktop, desktopScale: scale),
                      height: 1,
                      color: Colors.white.withAlpha(15),
                    ),
                    SizedBox(height: 8.rh(isDesktop, desktopScale: scale)),
                    InkWell(
                      onTap: widget.onManualIpTap,
                      borderRadius: BorderRadius.circular(
                        4.rr(isDesktop, desktopScale: scale),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.settings_ethernet_rounded,
                            size: 13.rx(isDesktop, desktopScale: scale),
                            color: AppColors.primary,
                          ),
                          SizedBox(width: 4.rw(isDesktop, desktopScale: scale)),
                          Text(
                            "MANUAL IP",
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 10.rx(isDesktop, desktopScale: scale),
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
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
                    Text(
                      widget.isReceiving
                          ? "SCANNING FOR PEERS"
                          : "RADAR OFFLINE",
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10.rx(isDesktop, desktopScale: scale),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    SizedBox(width: 12.rw(isDesktop, desktopScale: scale)),
                    Container(
                      width: 1,
                      height: 12.rh(isDesktop, desktopScale: scale),
                      color: Colors.white.withAlpha(10),
                    ),
                    SizedBox(width: 12.rw(isDesktop, desktopScale: scale)),
                    InkWell(
                      onTap: widget.onManualIpTap,
                      borderRadius: BorderRadius.circular(
                        4.rr(isDesktop, desktopScale: scale),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.settings_ethernet_rounded,
                            size: 13.rx(isDesktop, desktopScale: scale),
                            color: AppColors.primary,
                          ),
                          SizedBox(width: 4.rw(isDesktop, desktopScale: scale)),
                          Text(
                            "MANUAL IP",
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 10.rx(isDesktop, desktopScale: scale),
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
