import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';

class StatusDisplay extends StatelessWidget {
  const StatusDisplay({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransferCubit, TransferState>(
      buildWhen: (previous, current) => previous.model != current.model,
      builder: (context, state) {
        final model = state.model;
        return Container(
          padding: EdgeInsets.all(25.w),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(12), // withOpacity(0.05)
            borderRadius: BorderRadius.circular(25.r),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            children: [
              Text(
                model.status,
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 18.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 15.h),
              Text(
                "${model.speed.toStringAsFixed(1)} MB/s",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 50.sp,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (model.avgSpeed != null)
                Padding(
                  padding: EdgeInsets.only(top: 10.h),
                  child: Text(
                    "Avg: ${model.avgSpeed} MB/s | Time: ${model.totalTime}s",
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 16.sp,
                    ),
                  ),
                ),
              Divider(color: Colors.white10, height: 40.h),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _dataTile(
                    "Current File",
                    model.fileName.isEmpty ? "Ready" : model.fileName,
                  ),
                  _dataTile(
                    "Data Size",
                    "${model.transferred.toStringAsFixed(1)} MB",
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _dataTile(String label, String val) => Column(
    children: [
      Text(
        label,
        style: TextStyle(color: Colors.white54, fontSize: 12.sp),
      ),
      SizedBox(height: 5.h),
      Text(
        val,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 14.sp,
        ),
      ),
    ],
  );
}
