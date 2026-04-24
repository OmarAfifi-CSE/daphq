import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class InstructionsCard extends StatelessWidget {
  const InstructionsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(15.w),
      decoration: BoxDecoration(
        color: Colors.blue.withAlpha(25), // withOpacity (0.1) -> withAlpha (25)
        borderRadius: BorderRadius.circular(15.r),
        border: Border.all(color: Colors.blue.withAlpha(76)), // withOpacity(0.3) -> withAlpha(76)
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.blueAccent, size: 24.sp),
              SizedBox(width: 10.w),
              Expanded(child: Text("How to use for Max Speed", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16.sp))),
            ],
          ),
          SizedBox(height: 10.h),
          Text("1. Connect both devices to the same network (Wi-Fi or Hotspot).", style: TextStyle(color: Colors.white70, fontSize: 13.sp)),
          SizedBox(height: 5.h),
          Text("2. For max speed, one device should open a 5GHz Hotspot and the other connect to it.", style: TextStyle(color: Colors.white70, fontSize: 13.sp)),
          SizedBox(height: 5.h),
          Text("3. On the RECEIVER: Select a folder and click 'Start Receiver Server'.", style: TextStyle(color: Colors.white70, fontSize: 13.sp)),
          SizedBox(height: 5.h),
          Text("4. On the SENDER: Enter the Receiver's IP Address and select what to send.", style: TextStyle(color: Colors.white70, fontSize: 13.sp)),
        ],
      ),
    );
  }
}
