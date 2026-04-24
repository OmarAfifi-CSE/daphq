import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import 'widgets/instructions_card.dart';
import 'widgets/status_display.dart';
import 'widgets/receiver_section.dart';
import 'widgets/sender_section.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF12122A),
      appBar: (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          ? PreferredSize(
              preferredSize: const Size.fromHeight(kWindowCaptionHeight),
              child: WindowCaption(
                brightness: Brightness.dark,
                backgroundColor: Color(0xFF0F172A),
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
              backgroundColor: Color(0xFF0F172A),
              iconTheme: IconThemeData(color: Colors.white, size: 24.sp),
            ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            bool isDesktopWide = constraints.maxWidth > 800;

            if (isDesktopWide) {
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 1200),
                  child: Padding(
                    padding: EdgeInsets.all(20.w),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 1,
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            child: Column(
                              children: [
                                InstructionsCard(),
                                SizedBox(height: 20.h),
                                StatusDisplay(),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(width: 30.w),
                        Expanded(
                          flex: 1,
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: 500),
                                child: Column(
                                  children: [
                                    ReceiverSection(),
                                    SizedBox(height: 30.h),
                                    SenderSection(),
                                  ],
                                ),
                              ),
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
                constraints: BoxConstraints(maxWidth: 500),
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.all(20.w),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InstructionsCard(),
                      SizedBox(height: 20.h),
                      StatusDisplay(),
                      SizedBox(height: 30.h),
                      ReceiverSection(),
                      SizedBox(height: 30.h),
                      SenderSection(),
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
