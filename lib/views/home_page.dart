import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import '../core/app_colors.dart';
import '../services/update_service.dart';
import '../core/app_constants.dart';
import 'widgets/instructions_card.dart';
import 'widgets/transfer_progress_view.dart';
import 'widgets/receiver_section.dart';
import 'widgets/sender_section.dart';

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
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Colors.transparent,
        appBar: (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
            ? const PreferredSize(
                preferredSize: Size.fromHeight(kWindowCaptionHeight),
                child: WindowCaption(
                  brightness: Brightness.dark,
                  backgroundColor: AppColors.appBarBackground,
                  title: Text(
                    AppConstants.appName,
                    style: TextStyle(color: Colors.white, fontSize: 14),
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
              ),
        body: Container(
          color: AppColors.background,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                bool isDesktopWide = constraints.maxWidth > 800;
                final bool isDesktopOS =
                    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

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
                                      child: InstructionsCard(
                                        isDesktop: isDesktopOS,
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    _animatedStagger(
                                      index: 1,
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

                // Mobile / Narrow Layout
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: isDesktopOS
                          ? const EdgeInsets.all(20.0)
                          : EdgeInsets.all(20.w),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _animatedStagger(
                            index: 0,
                            child: InstructionsCard(isDesktop: isDesktopOS),
                          ),
                          SizedBox(height: isDesktopOS ? 20.0 : 20.h),
                          _animatedStagger(
                            index: 1,
                            child: TransferProgressView(isDesktop: isDesktopOS),
                          ),
                          SizedBox(height: isDesktopOS ? 30.0 : 30.h),
                          _animatedStagger(
                            index: 2,
                            child: ReceiverSection(isDesktop: isDesktopOS),
                          ),
                          SizedBox(height: isDesktopOS ? 30.0 : 30.h),
                          _animatedStagger(
                            index: 3,
                            child: SenderSection(isDesktop: isDesktopOS),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
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
        // Stagger logic: delay by 100ms per index
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
