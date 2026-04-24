import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class InstructionsCard extends StatelessWidget {
  final bool isDesktop;

  const InstructionsCard({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: isDesktop ? const EdgeInsets.all(15.0) : EdgeInsets.all(15.w),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(25),
        borderRadius: BorderRadius.circular(isDesktop ? 15.0 : 15.r),
        border: Border.all(color: Colors.blue.withAlpha(76)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Colors.blueAccent,
                size: isDesktop ? 24.0 : 24.sp,
              ),
              SizedBox(width: isDesktop ? 10.0 : 10.w),
              Expanded(
                child: Text(
                  "How to use for Max Speed",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: isDesktop ? 16.0 : 16.sp,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isDesktop ? 10.0 : 10.h),
          Text(
            "1. Connect both devices to the same network (Wi-Fi or Hotspot).",
            style: TextStyle(
              color: Colors.white70,
              fontSize: isDesktop ? 13.0 : 13.sp,
            ),
          ),
          SizedBox(height: isDesktop ? 5.0 : 5.h),
          Text(
            "2. For max speed, one device should open a 5GHz Hotspot and the other connect to it.",
            style: TextStyle(
              color: Colors.white70,
              fontSize: isDesktop ? 13.0 : 13.sp,
            ),
          ),
          SizedBox(height: isDesktop ? 5.0 : 5.h),
          Text(
            "3. On the RECEIVER: Select a folder and click 'Start Receiver Server'.",
            style: TextStyle(
              color: Colors.white70,
              fontSize: isDesktop ? 13.0 : 13.sp,
            ),
          ),
          SizedBox(height: isDesktop ? 5.0 : 5.h),
          Text(
            "4. On the SENDER: Enter the Receiver's IP Address and select what to send.",
            style: TextStyle(
              color: Colors.white70,
              fontSize: isDesktop ? 13.0 : 13.sp,
            ),
          ),
        ],
      ),
    );
  }
}
