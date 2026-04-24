import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class SenderSection extends StatefulWidget {
  final bool isDesktop;

  const SenderSection({super.key, this.isDesktop = false});

  @override
  _SenderSectionState createState() => _SenderSectionState();
}

class _SenderSectionState extends State<SenderSection> {
  late final TextEditingController _ipController;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(
      text: context.read<TransferCubit>().state.targetIp,
    );
    _ipController.addListener(() {
      context.read<TransferCubit>().setTargetIp(_ipController.text);
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String labelHint = "Receiver IP Address (e.g. 192.168.x.x)";
    final isDesktop = widget.isDesktop;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Sender Mode",
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
                  TextField(
                    controller: _ipController,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isDesktop ? 14.0 : 14.sp,
                    ),
                    decoration: InputDecoration(
                      labelText: labelHint,
                      labelStyle: TextStyle(
                        color: Colors.white38,
                        fontSize: isDesktop ? 14.0 : 14.sp,
                      ),
                      helperText: "Please update this to the exact Receiver IP",
                      helperStyle: TextStyle(
                        color: Colors.white60,
                        fontStyle: FontStyle.italic,
                        fontSize: isDesktop ? 12.0 : 12.sp,
                      ),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                    ),
                    enabled: !state.isTransferring,
                  ),
                  SizedBox(height: isDesktop ? 20.0 : 20.h),
                  Row(
                    children: [
                      Expanded(
                        child: _btn(
                          context,
                          Icons.file_copy,
                          "Send File",
                          false,
                          state,
                          isDesktop,
                        ),
                      ),
                      SizedBox(width: isDesktop ? 15.0 : 15.w),
                      Expanded(
                        child: _btn(
                          context,
                          Icons.folder,
                          "Send Folder",
                          true,
                          state,
                          isDesktop,
                        ),
                      ),
                    ],
                  ),
                  if (state.isTransferring && !state.isReceiving) ...[
                    SizedBox(height: isDesktop ? 15.0 : 15.h),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
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
                      onPressed: () {
                        context.read<TransferCubit>().cancelSending();
                      },
                      icon: Icon(
                        Icons.cancel,
                        color: Colors.white,
                        size: isDesktop ? 24.0 : 24.sp,
                      ),
                      label: Text(
                        "Cancel Transfer",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isDesktop ? 16.0 : 16.sp,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _btn(
    BuildContext context,
    IconData icon,
    String text,
    bool isFolder,
    TransferState state,
    bool isDesktop,
  ) {
    return ElevatedButton.icon(
      onPressed: state.isTransferring ? null : () => _pick(context, isFolder),
      icon: Icon(icon, color: Colors.white, size: isDesktop ? 20.0 : 20.sp),
      label: Text(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: isDesktop ? 14.0 : 14.sp,
        ),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blueAccent,
        minimumSize: Size(0, isDesktop ? 50.0 : 50.h),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isDesktop ? 15.0 : 15.r),
        ),
        disabledBackgroundColor: Colors.white12,
      ),
    );
  }

  Future<void> _pick(BuildContext context, bool isFolder) async {
    final cubit = context.read<TransferCubit>();
    if (cubit.state.isTransferring) return;

    String? path;
    if (isFolder) {
      path = await FilePicker.getDirectoryPath();
    } else {
      FilePickerResult? r = await FilePicker.pickFiles();
      path = r?.files.single.path;
    }

    if (path != null) {
      if (cubit.state.targetIp.trim().isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Please enter target IP!")));
        return;
      }
      cubit.sendData(path: path, isFolder: isFolder);
    }
  }
}
