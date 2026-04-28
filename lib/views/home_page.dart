import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import '../core/app_colors.dart';
import '../services/update_service.dart';
import 'widgets/instructions_card.dart';
import 'widgets/status_display.dart';
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          ? const PreferredSize(
              preferredSize: Size.fromHeight(kWindowCaptionHeight),
              child: WindowCaption(
                brightness: Brightness.dark,
                backgroundColor: AppColors.appBarBackground,
                title: Text(
                  'Turbo Transfer Pro',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            )
          : AppBar(
              title: Text(
                "Turbo Transfer Pro",
                style: TextStyle(color: Colors.white, fontSize: 20.sp),
              ),
              centerTitle: true,
              elevation: 0,
              backgroundColor: AppColors.appBarBackground,
              iconTheme: IconThemeData(color: Colors.white, size: 24.sp),
            ),
      body: SafeArea(
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
                                InstructionsCard(isDesktop: isDesktopOS),
                                const SizedBox(height: 20),
                                StatusDisplay(isDesktop: isDesktopOS),
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
                                ReceiverSection(isDesktop: isDesktopOS),
                                const SizedBox(height: 30),
                                SenderSection(isDesktop: isDesktopOS),
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
                      InstructionsCard(isDesktop: isDesktopOS),
                      SizedBox(height: isDesktopOS ? 20.0 : 20.h),
                      StatusDisplay(isDesktop: isDesktopOS),
                      SizedBox(height: isDesktopOS ? 30.0 : 30.h),
                      ReceiverSection(isDesktop: isDesktopOS),
                      SizedBox(height: isDesktopOS ? 30.0 : 30.h),
                      SenderSection(isDesktop: isDesktopOS),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
