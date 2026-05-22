import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';
import 'animated_press_button.dart';
import 'custom_snackbar.dart';

class TransferProgressView extends StatelessWidget {
  final bool isDesktop;

  const TransferProgressView({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    final scale = isDesktop ? context.desktopScale : 1.0;

    return BlocBuilder<TransferCubit, TransferState>(
      buildWhen: (previous, current) {
        final p = previous.model;
        final c = current.model;
        return p.progress != c.progress ||
            p.speed != c.speed ||
            p.status != c.status ||
            p.transferred != c.transferred ||
            p.totalSize != c.totalSize ||
            p.fileName != c.fileName ||
            p.analyzeCount != c.analyzeCount ||
            previous.isTransferring != current.isTransferring ||
            previous.isReceiving != current.isReceiving ||
            previous.isLastTransferIncoming != current.isLastTransferIncoming ||
            previous.showProgressView != current.showProgressView;
      },
      builder: (context, state) {
        final model = state.model;
        final bool hasProgress =
            model.totalSize > 0 ||
            model.progress > 0 ||
            model.analyzeCount != null;
        final status = model.status.toLowerCase();
        final bool isDone =
            status.contains("complete") || status.contains("success");
        final bool isFailed =
            status.contains("error") ||
            status.contains("failed") ||
            status.contains("cancelled") ||
            status.contains("rejected") ||
            status.contains("stopped");

        return AnimatedSize(
          duration: const Duration(milliseconds: 350),
          alignment: Alignment.topCenter,
          child: Container(
            padding: EdgeInsets.all(22.0.rw(isDesktop, desktopScale: scale)),
            decoration: BoxDecoration(
              color: AppColors.cardOverlay,
              borderRadius: BorderRadius.circular(
                22.0.rr(isDesktop, desktopScale: scale),
              ),
              border: Border.all(color: AppColors.cardBorder),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withAlpha(isDone ? 15 : 8),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              children: [
                // 1. Status Header
                Container(
                  width: double.infinity,
                  alignment: Alignment.center,
                  child: Text(
                    model.status.isEmpty ? "Ready & Waiting" : model.status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _getStatusColor(model.status),
                      fontSize: 18.0.rx(isDesktop, desktopScale: scale),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
                SizedBox(height: 10.0.rh(isDesktop, desktopScale: scale)),

                // 2. Speed Display — or File Count during analyze phase
                if (model.analyzeCount != null)
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeInOut,
                    builder: (context, value, _) {
                      return Text(
                        "${_formatCount(model.analyzeCount!)} files",
                        style: TextStyle(
                          color: AppColors.textPrimary.withAlpha(
                            (180 + (75 * value)).toInt(),
                          ),
                          fontSize: 38.0.rx(isDesktop, desktopScale: scale),
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(
                              color: AppColors.primary.withAlpha(120),
                              blurRadius: 20,
                            ),
                          ],
                        ),
                      );
                    },
                  )
                else
                  _SpeedDisplay(speed: model.speed, isDesktop: isDesktop),

                // 3. Avg Speed & Time Info / Estimated Time
                if (model.avgSpeed != null || model.totalTime != null)
                  Padding(
                    padding: EdgeInsets.only(
                      top: 5.0.rh(isDesktop, desktopScale: scale),
                    ),
                    child: Text(
                      "${model.avgSpeed != null ? "Avg: ${model.avgSpeed} MB/s" : ""}${model.avgSpeed != null && model.totalTime != null ? " | " : ""}${_formatCompletedTime(model.totalTime)}",
                      style: TextStyle(
                        color: AppColors.success.withAlpha(200),
                        fontSize: 15.0.rx(isDesktop, desktopScale: scale),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                else if (hasProgress && !isDone && !isFailed && model.speed > 0)
                  Padding(
                    padding: EdgeInsets.only(
                      top: 5.0.rh(isDesktop, desktopScale: scale),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          color: AppColors.primaryLight,
                          size: 16.0.rx(isDesktop, desktopScale: scale),
                        ),
                        SizedBox(width: 6.0.rw(isDesktop, desktopScale: scale)),
                        Text(
                          "Est. time: ${_formatEstimatedTime((model.totalSize - model.transferred) / model.speed)}",
                          style: TextStyle(
                            color: AppColors.primaryLight,
                            fontSize: 15.0.rx(isDesktop, desktopScale: scale),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                model.analyzeCount != null || hasProgress
                    ? SizedBox(height: 15.0.rh(isDesktop, desktopScale: scale))
                    : SizedBox(height: 20.0.rh(isDesktop, desktopScale: scale)),

                // 4. Compact Progress Section
                if (hasProgress) ...[
                  // File Name
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      model.fileName.isEmpty
                          ? "Preparing transfer..."
                          : model.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14.0.rx(isDesktop, desktopScale: scale),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  SizedBox(height: 8.0.rh(isDesktop, desktopScale: scale)),

                  // The Progress Bar
                  if (model.analyzeCount != null)
                    _AnalyzePulseBar(isDesktop: isDesktop)
                  else
                    _GlowingProgressBar(
                      progress: model.progress,
                      isDesktop: isDesktop,
                      isDone: isDone,
                      isFailed: isFailed,
                    ),
                  SizedBox(height: 8.0.rh(isDesktop, desktopScale: scale)),

                  // Progress Stats
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        isDone
                            ? "Transfer Complete"
                            : (isFailed
                                  ? "Transfer Cancelled"
                                  : "${(model.progress * 100).toInt()}% complete"),
                        style: TextStyle(
                          color: isDone
                              ? AppColors.success
                              : (isFailed
                                    ? AppColors.danger
                                    : AppColors.primaryLight),
                          fontSize: 12.0.rx(isDesktop, desktopScale: scale),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        "${_formatSize(model.transferred)}${model.totalSize > 0 ? " / ${_formatSize(model.totalSize)}" : ""}",
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12.0.rx(isDesktop, desktopScale: scale),
                        ),
                      ),
                    ],
                  ),
                  // Action Buttons
                  SizedBox(height: 18.0.rh(isDesktop, desktopScale: scale)),
                  (isDone || isFailed)
                      ? (isDesktop
                            ? Row(
                                children: [
                                  if (state.isLastTransferIncoming &&
                                      isDone) ...[
                                    Expanded(
                                      child: AnimatedPressButton(
                                        isDesktop: isDesktop,
                                        onPressed: () => context
                                            .read<TransferCubit>()
                                            .openReceivedFolder(),
                                        gradientColors: const [
                                          AppColors.primary,
                                          AppColors.primaryLight,
                                        ],
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.folder_open_rounded,
                                              color: Colors.white,
                                              size: 18.0.rx(
                                                isDesktop,
                                                desktopScale: scale,
                                              ),
                                            ),
                                            SizedBox(
                                              width: 6.rw(
                                                isDesktop,
                                                desktopScale: scale,
                                              ),
                                            ),
                                            Text(
                                              "Open Folder",
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13.0.rx(
                                                  isDesktop,
                                                  desktopScale: scale,
                                                ),
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 10.rw(
                                        isDesktop,
                                        desktopScale: scale,
                                      ),
                                    ),
                                  ],
                                  Expanded(
                                    child: AnimatedPressButton(
                                      isDesktop: isDesktop,
                                      onPressed: () => context
                                          .read<TransferCubit>()
                                          .dismissProgress(),
                                      gradientColors: isDone
                                          ? const [
                                              AppColors.success,
                                              AppColors.successLight,
                                            ]
                                          : [
                                              Colors.white.withAlpha(15),
                                              Colors.white.withAlpha(8),
                                            ],
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.check_circle_outline_rounded,
                                            color: isDone
                                                ? Colors.black87
                                                : AppColors.textSecondary,
                                            size: 18.0.rx(
                                              isDesktop,
                                              desktopScale: scale,
                                            ),
                                          ),
                                          SizedBox(
                                            width: 6.rw(
                                              isDesktop,
                                              desktopScale: scale,
                                            ),
                                          ),
                                          Text(
                                            isDone ? "Done" : "Dismiss",
                                            style: TextStyle(
                                              color: isDone
                                                  ? Colors.black87
                                                  : AppColors.textPrimary,
                                              fontSize: 13.0.rx(
                                                isDesktop,
                                                desktopScale: scale,
                                              ),
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                children: [
                                  if (state.isLastTransferIncoming &&
                                      isDone) ...[
                                    AnimatedPressButton(
                                      isDesktop: isDesktop,
                                      onPressed: () => context
                                          .read<TransferCubit>()
                                          .openReceivedFolder(),
                                      gradientColors: const [
                                        AppColors.primary,
                                        AppColors.primaryLight,
                                      ],
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.folder_open_rounded,
                                            color: Colors.white,
                                            size: 18.0.rx(
                                              isDesktop,
                                              desktopScale: scale,
                                            ),
                                          ),
                                          SizedBox(
                                            width: 6.rw(
                                              isDesktop,
                                              desktopScale: scale,
                                            ),
                                          ),
                                          Text(
                                            "Open Folder",
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 13.0.rx(
                                                isDesktop,
                                                desktopScale: scale,
                                              ),
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(
                                      height: 10.rh(
                                        isDesktop,
                                        desktopScale: scale,
                                      ),
                                    ),
                                  ],
                                  AnimatedPressButton(
                                    isDesktop: isDesktop,
                                    onPressed: () => context
                                        .read<TransferCubit>()
                                        .dismissProgress(),
                                    gradientColors: isDone
                                        ? const [
                                            AppColors.success,
                                            AppColors.successLight,
                                          ]
                                        : [
                                            Colors.white.withAlpha(15),
                                            Colors.white.withAlpha(8),
                                          ],
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.check_circle_outline_rounded,
                                          color: isDone
                                              ? Colors.black87
                                              : AppColors.textSecondary,
                                          size: 18.0.rx(
                                            isDesktop,
                                            desktopScale: scale,
                                          ),
                                        ),
                                        SizedBox(
                                          width: 6.rw(
                                            isDesktop,
                                            desktopScale: scale,
                                          ),
                                        ),
                                        Text(
                                          isDone ? "Done" : "Dismiss",
                                          style: TextStyle(
                                            color: isDone
                                                ? Colors.black87
                                                : AppColors.textPrimary,
                                            fontSize: 13.0.rx(
                                              isDesktop,
                                              desktopScale: scale,
                                            ),
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ))
                      : (state.isTransferring
                            ? AnimatedPressButton(
                                isDesktop: isDesktop,
                                onPressed: () {
                                  CustomSnackBar.hide();
                                  context.read<TransferCubit>().cancelSending();
                                },
                                gradientColors: const [
                                  AppColors.danger,
                                  AppColors.dangerLight,
                                ],
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.cancel_rounded,
                                      color: Colors.white,
                                      size: 18.0.rx(
                                        isDesktop,
                                        desktopScale: scale,
                                      ),
                                    ),
                                    SizedBox(
                                      width: 8.rw(
                                        isDesktop,
                                        desktopScale: scale,
                                      ),
                                    ),
                                    Text(
                                      "Cancel Transfer",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14.0.rx(
                                          isDesktop,
                                          desktopScale: scale,
                                        ),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : const SizedBox.shrink()),
                ] else ...[
                  // Minimal Placeholder
                  const SizedBox.shrink(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatCount(int count) {
    if (count >= 1000000) return "${(count / 1000000).toStringAsFixed(1)}M";
    if (count >= 1000) return "${(count / 1000).toStringAsFixed(1)}K";
    return count.toString();
  }

  Color _getStatusColor(String status) {
    final lower = status.toLowerCase();
    if (lower.contains("complete") || lower.contains("success")) {
      return AppColors.success;
    }
    if (lower.contains("error") ||
        lower.contains("fail") ||
        lower.contains("cancel")) {
      return AppColors.danger;
    }
    return AppColors.primary;
  }

  String _formatSize(double mb) {
    if (mb >= 1024) {
      return "${(mb / 1024).toStringAsFixed(2)} GB";
    }
    return "${mb.toStringAsFixed(1)} MB";
  }

  String _formatCompletedTime(String? totalTimeStr) {
    if (totalTimeStr == null) return "";
    double? seconds = double.tryParse(totalTimeStr);
    if (seconds == null) return "Time: ${totalTimeStr}s";

    if (seconds >= 60) {
      int minutes = (seconds / 60).floor();
      int remainingSeconds = (seconds % 60).toInt();
      return "Time: ${minutes}m ${remainingSeconds}s";
    }
    return "Time: ${seconds.toStringAsFixed(1)}s";
  }

  String _formatEstimatedTime(double secondsRemaining) {
    if (secondsRemaining.isInfinite ||
        secondsRemaining.isNaN ||
        secondsRemaining < 0) {
      return "Calculating...";
    }
    if (secondsRemaining < 60) {
      return "${secondsRemaining.toInt()}s";
    } else if (secondsRemaining < 3600) {
      final int minutes = (secondsRemaining / 60).toInt();
      final int seconds = (secondsRemaining % 60).toInt();
      return "${minutes}m ${seconds}s";
    } else {
      final int hours = (secondsRemaining / 3600).toInt();
      final int minutes = ((secondsRemaining % 3600) / 60).toInt();
      return "${hours}h ${minutes}m";
    }
  }
}

/// Speed display with text glow that intensifies with higher speed.
class _SpeedDisplay extends StatelessWidget {
  final double speed;
  final bool isDesktop;

  const _SpeedDisplay({required this.speed, required this.isDesktop});

  @override
  Widget build(BuildContext context) {
    final scale = isDesktop ? context.desktopScale : 1.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: speed),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final glowIntensity = (value * 3).clamp(0.0, 200.0).toInt();
        return Text(
          "${value.toStringAsFixed(1)} MB/s",
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 38.0.rx(isDesktop, desktopScale: scale),
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(
                color: AppColors.primary.withAlpha(glowIntensity),
                blurRadius: 20 + (value * 0.5).clamp(0, 15),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Glowing progress bar with particle effect at leading edge.
class _GlowingProgressBar extends StatelessWidget {
  final double progress;
  final bool isDesktop;
  final bool isDone;
  final bool isFailed;

  const _GlowingProgressBar({
    required this.progress,
    required this.isDesktop,
    required this.isDone,
    required this.isFailed,
  });

  @override
  Widget build(BuildContext context) {
    final scale = isDesktop ? context.desktopScale : 1.0;
    final colors = isDone
        ? [AppColors.success, AppColors.successLight]
        : (isFailed
              ? [AppColors.danger, AppColors.dangerLight]
              : [AppColors.primary, AppColors.primaryLight]);

    final barHeight = 6.rh(isDesktop, desktopScale: scale);
    final barRadius = 4.rr(isDesktop, desktopScale: scale);

    return LayoutBuilder(
      builder: (context, constraints) {
        final double progressWidth =
            constraints.maxWidth * progress.clamp(0.0, 1.0);
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              height: barHeight,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(8),
                borderRadius: BorderRadius.circular(barRadius),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
              height: barHeight,
              width: progressWidth,
              constraints: BoxConstraints(
                minWidth: progress > 0 ? barHeight : 0,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: colors),
                borderRadius: BorderRadius.circular(barRadius),
                boxShadow: [
                  BoxShadow(
                    color: colors.first.withAlpha(100),
                    blurRadius: 12.rr(isDesktop, desktopScale: scale),
                    offset: Offset(0, 2.rh(isDesktop, desktopScale: scale)),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Indeterminate sliding-pulse progress bar shown during the analyze phase.
class _AnalyzePulseBar extends StatefulWidget {
  final bool isDesktop;
  const _AnalyzePulseBar({required this.isDesktop});

  @override
  State<_AnalyzePulseBar> createState() => _AnalyzePulseBarState();
}

class _AnalyzePulseBarState extends State<_AnalyzePulseBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;
    final scale = isDesktop ? context.desktopScale : 1.0;
    final barHeight = 6.rh(isDesktop, desktopScale: scale);
    final barRadius = 4.rr(isDesktop, desktopScale: scale);
    final pulseWidth = 80.0.rw(isDesktop, desktopScale: scale);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        return AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final offset = _anim.value * (totalWidth + pulseWidth) - pulseWidth;
            return ClipRRect(
              borderRadius: BorderRadius.circular(barRadius),
              child: Stack(
                children: [
                  Container(
                    height: barHeight,
                    width: double.infinity,
                    color: Colors.white.withAlpha(8),
                  ),
                  Positioned(
                    left: offset,
                    child: Container(
                      height: barHeight,
                      width: pulseWidth,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.primary.withAlpha(0),
                            AppColors.primary,
                            AppColors.primaryLight,
                            AppColors.primary.withAlpha(0),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(barRadius),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(120),
                            blurRadius: 10.rr(isDesktop, desktopScale: scale),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
