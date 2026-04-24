import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
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
      appBar: AppBar(
        title: Text("Turbo Transfer Pro", style: TextStyle(color: Colors.white, fontSize: 20.sp)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Color(0xFF12122A),
        iconTheme: IconThemeData(color: Colors.white, size: 24.sp),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          bool isWide = constraints.maxWidth > 800;

          if (isWide) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 1200),
                child: Padding(
                  padding: EdgeInsets.all(20.w),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 5,
                        child: SingleChildScrollView(
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
                        flex: 6,
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              ReceiverSection(),
                              SizedBox(height: 30.h),
                              SenderSection(),
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
              constraints: BoxConstraints(maxWidth: 700),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(20.w),
                child: Column(
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
    );
  }
}
