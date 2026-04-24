import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';

class ReceiverSection extends StatelessWidget {
  final bool isDesktop;

  const ReceiverSection({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Receiver Mode",
          style: TextStyle(
            color: Colors.white,
            fontSize: isDesktop ? 20.0 : 20.sp,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: isDesktop ? 10.0 : 10.h),
        BlocBuilder<TransferCubit, TransferState>(
          builder: (context, state) {
            return Container(
              padding: isDesktop
                  ? const EdgeInsets.all(15.0)
                  : EdgeInsets.all(15.w),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(12),
                borderRadius: BorderRadius.circular(isDesktop ? 15.0 : 15.r),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message:
                              state.receiveFolder ??
                              "No receive folder selected",
                          child: Text(
                            state.receiveFolder == null
                                ? "No receive folder selected"
                                : "Save to: ${state.receiveFolder}",
                            style: TextStyle(
                              color: state.receiveFolder == null
                                  ? Colors.redAccent
                                  : Colors.greenAccent,
                              fontSize: isDesktop ? 14.0 : 14.sp,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.folder_open,
                          color: Colors.white,
                          size: isDesktop ? 24.0 : 24.sp,
                        ),
                        onPressed: state.isTransferring
                            ? null
                            : () async {
                                String? path =
                                    await FilePicker.getDirectoryPath();
                                if (path != null) {
                                  context
                                      .read<TransferCubit>()
                                      .setReceiveFolder(path);
                                }
                              },
                      ),
                    ],
                  ),
                  SizedBox(height: isDesktop ? 15.0 : 15.h),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isReceiving
                          ? Colors.red
                          : Colors.green,
                      minimumSize: Size(
                        double.infinity,
                        isDesktop ? 50.0 : 50.h,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          isDesktop ? 15.0 : 15.r,
                        ),
                      ),
                    ),
                    onPressed: state.isTransferring && !state.isReceiving
                        ? null
                        : () {
                            if (state.isReceiving) {
                              context.read<TransferCubit>().stopReceiver();
                            } else {
                              if (state.receiveFolder == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      "Please select a receive folder first!",
                                    ),
                                  ),
                                );
                                return;
                              }
                              context.read<TransferCubit>().startReceiver(
                                context: context,
                              );
                            }
                          },
                    icon: Icon(
                      state.isReceiving ? Icons.stop : Icons.wifi_tethering,
                      color: Colors.white,
                      size: isDesktop ? 24.0 : 24.sp,
                    ),
                    label: Text(
                      state.isReceiving
                          ? "Stop Receiver"
                          : "Start Receiver Server",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isDesktop ? 16.0 : 16.sp,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
