import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';

class TransferProgressView extends StatelessWidget {
  final bool isDesktop;

  const TransferProgressView({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
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
            p.analyzeCount != c.analyzeCount;
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
            padding: EdgeInsets.all(20.0.rw(isDesktop)),
            decoration: BoxDecoration(
              color: AppColors.cardOverlay,
              borderRadius: BorderRadius.circular(20.0.rr(isDesktop)),
              border: Border.all(color: AppColors.cardBorder),
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
                      fontSize: 18.0.rx(isDesktop),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                SizedBox(height: 10.0.rh(isDesktop)),

                // 2. Speed Display — or File Count during analyze phase
                if (model.analyzeCount != null)
                  // Analyze mode: show pulsing file counter instead of speed
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.easeInOut,
                    builder: (context, value, _) {
                      return Text(
                        "${_formatCount(model.analyzeCount!)} files",
                        style: TextStyle(
                          color: Colors.white.withAlpha(
                            (180 + (75 * value)).toInt(),
                          ),
                          fontSize: 38.0.rx(isDesktop),
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
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: model.speed),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (context, value, child) {
                      return Text(
                        "${value.toStringAsFixed(1)} MB/s",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 38.0.rx(isDesktop),
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(
                              color: AppColors.primary.withAlpha(
                                model.speed > 0 ? 150 : 0,
                              ),
                              blurRadius: 20,
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                // 3. Avg Speed & Time Info / Estimated Time
                if (model.avgSpeed != null || model.totalTime != null)
                  Padding(
                    padding: EdgeInsets.only(top: 5.0.rh(isDesktop)),
                    child: Text(
                      "${model.avgSpeed != null ? "Avg: ${model.avgSpeed} MB/s" : ""}${model.avgSpeed != null && model.totalTime != null ? " | " : ""}${_formatCompletedTime(model.totalTime)}",
                      style: TextStyle(
                        color: Colors.greenAccent.withAlpha(180),
                        fontSize: 16.0.rx(isDesktop),
                      ),
                    ),
                  )
                else if (hasProgress && !isDone && !isFailed && model.speed > 0)
                  Padding(
                    padding: EdgeInsets.only(top: 5.0.rh(isDesktop)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          color: AppColors.primaryLight,
                          size: 16.0.rx(isDesktop),
                        ),
                        SizedBox(width: 6.0.rw(isDesktop)),
                        Text(
                          "Est. time: ${_formatEstimatedTime((model.totalSize - model.transferred) / model.speed)}",
                          style: TextStyle(
                            color: AppColors.primaryLight,
                            fontSize: 15.0.rx(isDesktop),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                model.analyzeCount != null || hasProgress
                    ? SizedBox(height: 15.0.rh(isDesktop))
                    : SizedBox(height: 20.0.rh(isDesktop)),

                // 4. Compact Progress Section (Unified)
                if (hasProgress) ...[
                  // File Name Above Bar
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      model.fileName.isEmpty
                          ? "Preparing transfer..."
                          : model.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.0.rx(isDesktop),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  SizedBox(height: 8.0.rh(isDesktop)),

                  // The Bar
                  if (model.analyzeCount != null)
                    // Indeterminate pulse bar during analyze
                    _AnalyzePulseBar(isDesktop: isDesktop)
                  else
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final double progressWidth =
                            constraints.maxWidth *
                            model.progress.clamp(0.0, 1.0);
                        return Stack(
                          children: [
                            Container(
                              height: 8,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 400),
                              height: 8,
                              width: progressWidth,
                              constraints: BoxConstraints(
                                minWidth: model.progress > 0 ? 6 : 0,
                              ),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    AppColors.primary,
                                    AppColors.primaryLight,
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(5),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary.withAlpha(100),
                                    blurRadius: 10,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  SizedBox(height: 8.0.rh(isDesktop)),

                  // Progress Stats Below Bar
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
                          color: AppColors.primaryLight,
                          fontSize: 12.0.rx(isDesktop),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        "${_formatSize(model.transferred)}${model.totalSize > 0 ? " / ${_formatSize(model.totalSize)}" : ""}",
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12.0.rx(isDesktop),
                        ),
                      ),
                    ],
                  ),
                  if (state.isLastTransferIncoming && isDone) ...[
                    SizedBox(height: 15.0.rh(isDesktop)),
                    Align(
                      alignment: Alignment.center,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isDesktop
                              ? 220
                              : MediaQuery.sizeOf(context).width,
                          maxHeight: 80.0.rh(isDesktop),
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => context
                                .read<TransferCubit>()
                                .openReceivedFolder(),
                            icon: Icon(
                              Icons.folder_open_rounded,
                              size: 18.0.rx(isDesktop),
                            ),
                            label: Text(
                              "Open Received Folder",
                              style: TextStyle(fontSize: 14.0.rx(isDesktop)),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary.withAlpha(40),
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(
                                vertical: isDesktop ? 20 : 12.0.rh(isDesktop),
                                horizontal: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  12.0.rr(isDesktop),
                                ),
                                side: const BorderSide(
                                  color: AppColors.primary,
                                ),
                              ),
                              elevation: 0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ] else ...[
                  // Minimal Placeholder when no progress
                  const Divider(color: Colors.white10),
                  Text(
                    "Waiting for data transmission...",
                    style: TextStyle(
                      color: Colors.white24,
                      fontSize: 13.0.rx(isDesktop),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        const pulseWidth = 80.0;
        return AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            final offset = _anim.value * (totalWidth + pulseWidth) - pulseWidth;
            return ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Stack(
                children: [
                  Container(
                    height: 8,
                    width: double.infinity,
                    color: Colors.white10,
                  ),
                  Positioned(
                    left: offset,
                    child: Container(
                      height: 8,
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
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(120),
                            blurRadius: 10,
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
