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
            p.fileName != c.fileName;
      },
      builder: (context, state) {
        final model = state.model;
        final bool hasProgress = model.totalSize > 0 || model.progress > 0;
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

                // 2. Huge Speed Display
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
                      "${model.avgSpeed != null ? "Avg: ${model.avgSpeed} MB/s" : ""} ${model.totalTime != null ? " | Time: ${model.totalTime}s" : ""}",
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

                hasProgress
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
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final double progressWidth =
                          constraints.maxWidth * model.progress.clamp(0.0, 1.0);
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
                        "${model.transferred.toStringAsFixed(1)}${model.totalSize > 0 ? " / ${model.totalSize.toStringAsFixed(1)}" : ""} MB",
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12.0.rx(isDesktop),
                        ),
                      ),
                    ],
                  ),
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

  Color _getStatusColor(String status) {
    return AppColors.primary;
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
