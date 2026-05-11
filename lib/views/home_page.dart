import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import '../core/app_colors.dart';
import '../services/update_service.dart';
import '../core/app_constants.dart';
import 'widgets/common/info_dialog.dart';
import 'widgets/common/transfer_progress_view.dart';
import 'widgets/receiver/receiver_section.dart';
import 'widgets/sender/sender_section.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UpdateService.checkForUpdates(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: BlocListener<TransferCubit, TransferState>(
        listenWhen: (previous, current) =>
            (previous.authRequest != current.authRequest &&
                current.authRequest != null) ||
            (previous.errorMessage != current.errorMessage &&
                current.errorMessage != null) ||
            (previous.showStorageSettingsDialog !=
                    current.showStorageSettingsDialog &&
                current.showStorageSettingsDialog) ||
            (previous.showNotificationWarningDialog !=
                    current.showNotificationWarningDialog &&
                current.showNotificationWarningDialog),
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
                textColor: Colors.indigoAccent,
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
                  borderRadius: BorderRadius.circular(12),
                ),
                content: const Text(
                  AppConstants.storagePermissionRequired,
                  style: TextStyle(color: Colors.white),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text(
                      AppConstants.cancel,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      openAppSettings();
                      Navigator.pop(dialogContext);
                    },
                    child: const Text(
                      AppConstants.openSettings,
                      style: TextStyle(color: Colors.blue),
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
                  borderRadius: BorderRadius.circular(12),
                ),
                content: const Text(
                  AppConstants.notificationPermissionWarning,
                  style: TextStyle(color: Colors.white),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      cubit.resolveNotificationWarning(true);
                    },
                    child: const Text(
                      AppConstants.proceedAnyway,
                      style: TextStyle(color: Colors.white70),
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
                      style: TextStyle(color: Colors.blue),
                    ),
                  ),
                ],
              ),
            );
            cubit.clearFeedback();
          }

          if (state.authRequest != null) {
            showAuthDialog(
              context: context,
              senderIp: state.authRequest!.senderIp,
              fileCount: state.authRequest!.fileCount,
              totalSizeMB: state.authRequest!.totalSizeMB,
            ).then((accepted) {
              cubit.resolveAuth(accepted);
            });
          }
        },
        child: Scaffold(
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
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Material(
                          type: MaterialType.transparency,
                          child: IconButton(
                            onPressed: () => InfoDialog.show(context),
                            icon: const Icon(
                              Icons.help_outline_rounded,
                              color: Colors.white70,
                              size: 20,
                            ),
                            padding: EdgeInsets.zero,
                            splashRadius: 20,
                            constraints: const BoxConstraints(),
                            tooltip: "How to use",
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : AppBar(
                  title: Text(
                    AppConstants.appName,
                    style: TextStyle(color: Colors.white, fontSize: 20.sp),
                  ),
                  centerTitle: true,
                  elevation: 0,
                  backgroundColor: Colors.transparent,
                  iconTheme: IconThemeData(color: Colors.white, size: 24.sp),
                  actions: [
                    IconButton(
                      onPressed: () => InfoDialog.show(context),
                      icon: const Icon(
                        Icons.help_outline_rounded,
                        color: Colors.white70,
                      ),
                      tooltip: "How to use",
                    ),
                  ],
                ),
          body: Container(
            color: AppColors.background,
            child: SafeArea(
              child: Column(
                children: [
                  DiscoveryStatusBanner(
                    discoveryService: context.read<TransferCubit>().discovery,
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        bool isDesktopWide = constraints.maxWidth > 800;
                        final bool isDesktopOS =
                            Platform.isWindows ||
                            Platform.isMacOS ||
                            Platform.isLinux;

                        if (isDesktopWide) {
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1100),
                              child: Padding(
                                padding: const EdgeInsets.all(20.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 1,
                                      child: SingleChildScrollView(
                                        physics: const BouncingScrollPhysics(),
                                        child: Column(
                                          children: [
                                            _animatedStagger(
                                              index: 0,
                                              child: TransferProgressView(
                                                isDesktop: isDesktopOS,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 30),
                                    Expanded(
                                      flex: 1,
                                      child: SingleChildScrollView(
                                        physics: const BouncingScrollPhysics(),
                                        child: Column(
                                          children: [
                                            _animatedStagger(
                                              index: 2,
                                              child: ReceiverSection(
                                                isDesktop: isDesktopOS,
                                              ),
                                            ),
                                            const SizedBox(height: 30),
                                            _animatedStagger(
                                              index: 3,
                                              child: SenderSection(
                                                isDesktop: isDesktopOS,
                                              ),
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
                        }

                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 500),
                            child: SingleChildScrollView(
                              physics: isDesktopOS
                                  ? const ClampingScrollPhysics()
                                  : const BouncingScrollPhysics(),
                              padding: isDesktopOS
                                  ? const EdgeInsets.all(20.0)
                                  : EdgeInsets.all(20.w),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _animatedStagger(
                                    index: 0,
                                    child: TransferProgressView(
                                      isDesktop: isDesktopOS,
                                    ),
                                  ),
                                  SizedBox(height: isDesktopOS ? 30.0 : 30.h),
                                  _animatedStagger(
                                    index: 1,
                                    child: ReceiverSection(
                                      isDesktop: isDesktopOS,
                                    ),
                                  ),
                                  SizedBox(height: isDesktopOS ? 30.0 : 30.h),
                                  _animatedStagger(
                                    index: 2,
                                    child: SenderSection(
                                      isDesktop: isDesktopOS,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _animatedStagger({required int index, required Widget child}) {
    return TweenAnimationBuilder<double>(
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
