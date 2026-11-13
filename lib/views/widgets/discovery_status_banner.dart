import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/discovery_service.dart';
import '../../core/app_colors.dart';
import '../../core/app_constants.dart';

class DiscoveryStatusBanner extends StatefulWidget {
  final DiscoveryService discoveryService;

  const DiscoveryStatusBanner({
    super.key,
    required this.discoveryService,
  });

  @override
  State<DiscoveryStatusBanner> createState() => _DiscoveryStatusBannerState();
}

class _DiscoveryStatusBannerState extends State<DiscoveryStatusBanner> {
  ServiceStatus? _lastStatus;
  bool _showConnected = false;
  Timer? _hideTimer;
  StreamSubscription<ServiceStatus>? _statusSubscription;

  @override
  void initState() {
    super.initState();
    _statusSubscription = widget.discoveryService.statusStream.listen((status) {
      if (status == ServiceStatus.discovering &&
          (_lastStatus == ServiceStatus.recovering || _lastStatus == ServiceStatus.failed)) {
        setState(() {
          _showConnected = true;
        });
        _hideTimer?.cancel();
        _hideTimer = Timer(const Duration(seconds: 4), () {
          if (mounted) {
            setState(() {
              _showConnected = false;
            });
          }
        });
      }
      _lastStatus = status;
      if (status != ServiceStatus.discovering) {
        setState(() {
          _showConnected = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ServiceStatus>(
      stream: widget.discoveryService.statusStream,
      initialData: widget.discoveryService.status,
      builder: (context, snapshot) {
        final status = snapshot.data ?? ServiceStatus.idle;

        return AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _buildContent(status),
          ),
        );
      },
    );
  }

  Widget _buildContent(ServiceStatus status) {
    if (_showConnected) {
      return const _BannerContainer(
        key: ValueKey('connected'),
        message: AppConstants.discoveryStatusConnected,
        icon: Icons.check_circle_rounded,
        color: AppColors.discoverySuccess,
      );
    }

    if (status == ServiceStatus.recovering) {
      return const _BannerContainer(
        key: ValueKey('recovering'),
        message: AppConstants.discoveryStatusSearching,
        icon: Icons.loop_rounded,
        isSpinning: true,
        hasShimmer: true,
        color: AppColors.discoveryRecovering,
      );
    }

    if (status == ServiceStatus.failed) {
      return _BannerContainer(
        key: const ValueKey('failed'),
        message: AppConstants.discoveryConflictTitle,
        icon: Icons.warning_amber_rounded,
        color: AppColors.discoveryFailed,
        trailing: TextButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: AppColors.dialogBackground,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                title: const Text(
                  AppConstants.discoveryConflictHowTo,
                  style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
                ),
                content: const Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppConstants.discoveryConflictDesc,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                    SizedBox(height: 16),
                    Text(AppConstants.discoveryConflictStep1, style: TextStyle(color: AppColors.textPrimary)),
                    SizedBox(height: 8),
                    Text(AppConstants.discoveryConflictStep2, style: TextStyle(color: AppColors.textPrimary)),
                    SizedBox(height: 8),
                    Text(AppConstants.discoveryConflictStep3, style: TextStyle(color: AppColors.textPrimary)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(AppConstants.discoveryConflictGotIt, style: TextStyle(color: AppColors.textMuted)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      widget.discoveryService.forceReopen();
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text(AppConstants.discoveryConflictTryAgain),
                  ),
                ],
              ),
            );
          },
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.white.withAlpha(25),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text(AppConstants.discoveryConflictHowTo),
        ),
      );
    }

    if (status == ServiceStatus.noConnection) {
      return const _BannerContainer(
        key: ValueKey('no_connection'),
        message: AppConstants.discoveryStatusNoConnection,
        icon: Icons.signal_wifi_off_rounded,
        color: AppColors.discoveryNoConnection,
      );
    }

    return const SizedBox.shrink(key: ValueKey('none'));
  }
}

class _BannerContainer extends StatefulWidget {
  final String message;
  final IconData icon;
  final Color color;
  final bool isSpinning;
  final bool hasShimmer;
  final Widget? trailing;

  const _BannerContainer({
    super.key,
    required this.message,
    required this.icon,
    required this.color,
    this.isSpinning = false,
    this.hasShimmer = false,
    this.trailing,
  });

  @override
  State<_BannerContainer> createState() => _BannerContainerState();
}

class _BannerContainerState extends State<_BannerContainer>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    if (widget.hasShimmer) _shimmerController.repeat();
  }

  @override
  void didUpdateWidget(covariant _BannerContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.hasShimmer && !_shimmerController.isAnimating) {
      _shimmerController.repeat();
    } else if (!widget.hasShimmer && _shimmerController.isAnimating) {
      _shimmerController.stop();
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double bannerWidth = MediaQuery.sizeOf(context).width;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _shimmerController,
        builder: (context, child) {
          return Container(
            width: bannerWidth,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                widget.color,
                widget.color.withAlpha(200),
                widget.color,
              ],
              stops: widget.hasShimmer
                  ? [
                      (_shimmerController.value - 0.3).clamp(0.0, 1.0),
                      _shimmerController.value,
                      (_shimmerController.value + 0.3).clamp(0.0, 1.0),
                    ]
                  : const [0.0, 0.5, 1.0],
            ),
          ),
          child: child,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Builder(
          builder: (context) {
            final bool isMobile = MediaQuery.of(context).size.width < 450;
            if (isMobile && widget.trailing != null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.isSpinning)
                        const _SpinningIcon(icon: Icons.sync_rounded)
                      else
                        Icon(widget.icon, color: Colors.white, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: widget.trailing,
                  ),
                ],
              );
            }
            return Row(
              children: [
                if (widget.isSpinning)
                  const _SpinningIcon(icon: Icons.sync_rounded)
                else
                  Icon(widget.icon, color: Colors.white, size: 20),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    widget.message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
                // ignore: use_null_aware_elements
                if (widget.trailing != null) ...[
                  const SizedBox(width: 12),
                  widget.trailing!,
                ],
              ],
            );
          },
        ),
      ),
    ),
  );
  }
}

class _SpinningIcon extends StatefulWidget {
  final IconData icon;
  const _SpinningIcon({required this.icon});

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(widget.icon, color: Colors.white, size: 20),
    );
  }
}
