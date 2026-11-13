import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import '../core/app_colors.dart';
import '../core/responsive_utils.dart';
import '../services/update_service.dart';
import '../core/app_constants.dart';
import 'widgets/common/info_dialog.dart';
import 'widgets/common/history_dialog.dart';
import 'widgets/common/transfer_progress_view.dart';
import 'widgets/common/unified_dashboard.dart';
import 'widgets/common/animated_background.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../cubits/transfer_cubit.dart';
import '../cubits/transfer_state.dart';
import 'widgets/receiver/auth_dialog.dart';
import 'widgets/common/custom_snackbar.dart';
import 'widgets/discovery_status_banner.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DialogRoute<bool>? _authDialogRoute;
  AuthRequest? _activeAuthRequest;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UpdateService.checkForUpdates(context);
    });
  }

  @override
  void dispose() {
    _authDialogRoute = null;
    _activeAuthRequest = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget scaffold = Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          ? PreferredSize(
              preferredSize: const Size.fromHeight(kWindowCaptionHeight),
              child: WindowCaption(
                brightness: Brightness.dark,
                backgroundColor: AppColors.appBarBackground,
                title: Row(
                  children: [
                    Image.asset(
                      'assets/logo.png',
                      width: 16,
                      height: 16,
                      filterQuality: FilterQuality.high,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      AppConstants.appName,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : AppBar(
                        scrolledUnderElevation: 0,
                        leadingWidth: 60.w,
                        flexibleSpace: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppColors.background.withAlpha(140),
                              ),
                            ),
                          ),
                        ),
                        leading: Padding(
                          padding: EdgeInsets.only(left: 12.w),
                          child: Center(
                            child: Container(
                              width: 38.w,
                              height: 38.w,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary.withAlpha(25),
                                border: Border.all(
                                  color: AppColors.primary.withAlpha(90),
                                  width: 1.0,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary.withAlpha(15),
                                    blurRadius: 8,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                onPressed: () => InfoDialog.show(context),
                                icon: Icon(
                                  Icons.info_outline_rounded,
                                  color: AppColors.primaryLight.withAlpha(220),
                                  size: 18.sp,
                                ),
                                tooltip: "How to use",
                              ),
                            ),
                          ),
                        ),
                        title: ShaderMask(
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [
                              Color.fromARGB(
                                255,
                                128,
                                217,
                                255,
                              ), // Vibrant neon cyan/ice blue
                              AppColors
                                  .primaryLight, // Premium theme light blue
                              AppColors.primary, // Electric primary blue
                            ],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ).createShader(bounds),
                          child: Text(
                            "DAPHQ",
                            style: TextStyle(
                              fontSize: 22.sp,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3.5,
                              fontFamily: 'Roboto',
                              color: Colors.white,
                              shadows: [
                                Shadow(
                                  color: AppColors.primary.withAlpha(100),
                                  blurRadius: 12,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                        centerTitle: true,
                        elevation: 0,
                        backgroundColor: Colors.transparent,
                        actions: [
                          Padding(
                            padding: EdgeInsets.only(right: 12.w),
                            child: Center(
                              child: Container(
                                width: 38.w,
                                height: 38.w,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary.withAlpha(25),
                                  border: Border.all(
                                    color: AppColors.primary.withAlpha(90),
                                    width: 1.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primary.withAlpha(15),
                                      blurRadius: 8,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  onPressed: () => HistoryDialog.show(
                                    context,
                                    isDesktop: false,
                                  ),
                                  icon: Icon(
                                    Icons.history_rounded,
                                    color: AppColors.primaryLight.withAlpha(
                                      220,
                                    ),
                                    size: 18.sp,
                                  ),
                                  tooltip: "Transfer History",
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                body: Stack(
                  children: [
                    // Background layer
                    Container(color: AppColors.background),
                    // Animated particle field
                    const RepaintBoundary(child: AnimatedBackground()),
                    // Main content
                    SafeArea(
                      child: Column(
                        children: [
                          DiscoveryStatusBanner(
                            discoveryService: context
                                .read<TransferCubit>()
                                .discovery,
                          ),
                          Expanded(
                            child: BlocSelector<
                              TransferCubit,
                              TransferState,
                              ({bool showProgressView, String? receiveFolder})
                            >(
                              selector: (state) => (
                                showProgressView: state.showProgressView,
                                receiveFolder: state.receiveFolder,
                              ),
                              builder: (context, viewState) {
                                return LayoutBuilder(
                                  builder: (context, constraints) {
                                    final bool isDesktopOS =
                                        Platform.isWindows ||
                                        Platform.isMacOS ||
                                        Platform.isLinux;
                                    final double desktopScale = isDesktopOS
                                        ? context.desktopScale
                                        : 1.0;
                                    final double maxDashWidth =
                                        500.0 * desktopScale;

                                    return Align(
                                      alignment: Alignment.center,
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: maxDashWidth,
                                        ),
                                        child: SingleChildScrollView(
                                          key: isDesktopOS
                                              ? ValueKey(
                                                  'desktop_scroll_${viewState.showProgressView}_${viewState.receiveFolder ?? ""}',
                                                )
                                              : null,
                                          physics: isDesktopOS
                                              ? const ClampingScrollPhysics()
                                              : const BouncingScrollPhysics(),
                                          padding: isDesktopOS
                                              ? const EdgeInsets.all(20.0)
                                              : EdgeInsets.fromLTRB(
                                                  20.w,
                                                  10.w,
                                                  20.w,
                                                  20.w,
                                                ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 300,
                                                ),
                                                switchInCurve:
                                                    Curves.easeInOutCubic,
                                                switchOutCurve:
                                                    Curves.easeInOutCubic,
                                                child: viewState.showProgressView
                                                    ? _animatedStagger(
                                                        key: const ValueKey(
                                                          'progress_view',
                                                        ),
                                                        index: 0,
                                                        child:
                                                            TransferProgressView(
                                                              isDesktop:
                                                                  isDesktopOS,
                                                            ),
                                                      )
                                                    : _animatedStagger(
                                                        key: const ValueKey(
                                                          'unified_dashboard',
                                                        ),
                                                        index: 0,
                                                        child: UnifiedDashboard(
                                                          isDesktop:
                                                              isDesktopOS,
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
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Elegant Glassmorphic Loading Overlay
                    BlocSelector<TransferCubit, TransferState, bool>(
                      selector: (state) => state.isAddingFiles,
                      builder: (context, isAddingFiles) {
                        if (!isAddingFiles) return const SizedBox.shrink();
                        return Positioned.fill(
                          child: ClipRect(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                color: AppColors.background.withAlpha(180),
                                alignment: Alignment.center,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const CircularProgressIndicator(
                                      color: AppColors.primary,
                                      strokeWidth: 3,
                                    ),
                                    SizedBox(height: 24.h),
                                    Text(
                                      "Processing files...",
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16.sp,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                floatingActionButton:
                    (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'history_fab',
                            onPressed: () =>
                                HistoryDialog.show(context, isDesktop: true),
                            backgroundColor: AppColors.primary.withAlpha(20),
                            elevation: 0,
                            hoverElevation: 4,
                            highlightElevation: 0,
                            tooltip: "Transfer History",
                            child: Icon(
                              Icons.history_rounded,
                              color: AppColors.primaryLight.withAlpha(120),
                              size: 20,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FloatingActionButton.small(
                            heroTag: 'info_fab',
                            onPressed: () => InfoDialog.show(context),
                            backgroundColor: AppColors.primary.withAlpha(20),
                            elevation: 0,
                            hoverElevation: 4,
                            highlightElevation: 0,
                            tooltip: "How to use",
                            child: Icon(
                              Icons.info_outline_rounded,
                              color: AppColors.primaryLight.withAlpha(120),
                              size: 20,
                            ),
                          ),
                        ],
                      )
                    : null,
    );

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: BlocListener<TransferCubit, TransferState>(
        listenWhen: (previous, current) =>
            previous.authRequest != current.authRequest ||
            (previous.errorMessage != current.errorMessage &&
                current.errorMessage != null) ||
            (previous.showStorageSettingsDialog !=
                    current.showStorageSettingsDialog &&
                current.showStorageSettingsDialog) ||
            (previous.showNotificationWarningDialog !=
                    current.showNotificationWarningDialog &&
                current.showNotificationWarningDialog) ||
            (previous.showBatteryOptimizationSnackBar !=
                    current.showBatteryOptimizationSnackBar &&
                current.showBatteryOptimizationSnackBar),
        listener: (context, state) {
          final cubit = context.read<TransferCubit>();

          if (state.errorMessage != null) {
            CustomSnackBar.show(
              context,
              message: state.errorMessage!,
              duration: const Duration(seconds: 4),
            );
            cubit.clearFeedback();
          }

          if (state.showBatteryOptimizationSnackBar) {
            CustomSnackBar.show(
              context,
              message: "Disable battery limits for speed & stable transfers.",
              duration: const Duration(seconds: 3),
              action: SnackBarAction(
                label: "DISABLE",
                textColor: AppColors.primaryLight,
                onPressed: () =>
                    Permission.ignoreBatteryOptimizations.request(),
              ),
            );
            cubit.clearFeedback();
          }

          if (state.showStorageSettingsDialog) {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) => AlertDialog(
                backgroundColor: AppColors.dialogBackground,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                content: const Text(
                  AppConstants.storagePermissionRequired,
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text(
                      AppConstants.cancel,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      openAppSettings();
                      Navigator.pop(dialogContext);
                    },
                    child: const Text(
                      AppConstants.openSettings,
                      style: TextStyle(color: AppColors.primary),
                    ),
                  ),
                ],
              ),
            );
            cubit.clearFeedback();
          }

          if (state.showNotificationWarningDialog) {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (dialogContext) => AlertDialog(
                backgroundColor: AppColors.dialogBackground,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                content: const Text(
                  AppConstants.notificationPermissionWarning,
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      cubit.resolveNotificationWarning(true);
                    },
                    child: const Text(
                      AppConstants.proceedAnyway,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      openAppSettings();
                      Navigator.pop(dialogContext);
                      cubit.resolveNotificationWarning(false);
                    },
                    child: const Text(
                      AppConstants.openSettings,
                      style: TextStyle(color: AppColors.primary),
                    ),
                  ),
                ],
              ),
            );
            cubit.clearFeedback();
          }

          final req = state.authRequest;
          if (req == null && _activeAuthRequest != null) {
            final route = _authDialogRoute;
            _authDialogRoute = null;
            _activeAuthRequest = null;
            if (route != null && route.isActive && mounted) {
              Navigator.of(context, rootNavigator: true).removeRoute(route);
            }
          } else if (req != null && !identical(_activeAuthRequest, req)) {
            final previousRoute = _authDialogRoute;
            if (previousRoute != null && previousRoute.isActive && mounted) {
              Navigator.of(
                context,
                rootNavigator: true,
              ).removeRoute(previousRoute);
            }
            final route = createAuthDialogRoute(
              context: context,
              senderIp: req.senderIp,
              senderName: req.senderName,
              fileCount: req.fileCount,
              formattedSize: req.formattedSize,
            );
            _activeAuthRequest = req;
            _authDialogRoute = route;
            Navigator.of(context, rootNavigator: true).push<bool>(route).then((
              accepted,
            ) {
              if (identical(_activeAuthRequest, req)) {
                _activeAuthRequest = null;
                _authDialogRoute = null;
                if (mounted) {
                  cubit.resolveAuth(accepted ?? false);
                }
              }
            });
          }
        },
        child: BlocSelector<
          TransferCubit,
          TransferState,
          ({bool showProgressView, bool isTransferring, bool isReceivingActive})
        >(
          selector: (state) => (
            showProgressView: state.showProgressView,
            isTransferring: state.isTransferring,
            isReceivingActive: state.isReceivingActive,
          ),
          builder: (context, popState) {
            return PopScope(
              canPop:
                  !popState.showProgressView ||
                  popState.isTransferring ||
                  popState.isReceivingActive,
              onPopInvokedWithResult: (didPop, result) {
                if (didPop) return;
                if (popState.showProgressView &&
                    !popState.isTransferring &&
                    !popState.isReceivingActive) {
                  context.read<TransferCubit>().dismissProgress();
                }
              },
              child: scaffold,
            );
          },
        ),
      ),
    );
  }

  Widget _animatedStagger({
    Key? key,
    required int index,
    required Widget child,
  }) {
    return TweenAnimationBuilder<double>(
      key: key,
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final double delay = index * 0.15;
        final double adjustedValue = ((value - delay) / (1 - delay)).clamp(
          0.0,
          1.0,
        );
        return Opacity(
          opacity: adjustedValue,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - adjustedValue)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
