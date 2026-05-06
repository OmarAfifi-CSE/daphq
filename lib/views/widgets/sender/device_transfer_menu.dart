import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import '../common/animated_press_button.dart';
import '../common/custom_snackbar.dart';

class DeviceTransferMenu extends StatelessWidget {
  final String ip;
  final String name;
  final bool isDesktop;

  const DeviceTransferMenu({
    super.key,
    required this.ip,
    required this.name,
    required this.isDesktop,
  });

  static void show(
    BuildContext context,
    String ip,
    String name,
    bool isDesktop,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.dialogBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) =>
          DeviceTransferMenu(ip: ip, name: name, isDesktop: isDesktop),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.all(20.rr(isDesktop)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Send to $name",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18.rx(isDesktop),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 20.rh(isDesktop)),
                Row(
                  children: [
                    Expanded(
                      child: _MenuButton(
                        icon: Icons.file_copy,
                        text: AppConstants.sendFile,
                        isDesktop: isDesktop,
                        onPressed: () =>
                            _pickAndSend(context, ip, false, state),
                      ),
                    ),
                    SizedBox(width: 15.rw(isDesktop)),
                    Expanded(
                      child: _MenuButton(
                        icon: Icons.folder,
                        text: AppConstants.sendFolder,
                        isDesktop: isDesktop,
                        onPressed: () => _pickAndSend(context, ip, true, state),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10.rh(isDesktop)),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickAndSend(
    BuildContext context,
    String ip,
    bool isFolder,
    TransferState state,
  ) async {
    if (state.isTransferring) {
      CustomSnackBar.show(
        context,
        message: "A transfer is already in progress.",
      );
      return;
    }

    final cubit = context.read<TransferCubit>();
    Navigator.pop(context); // Close sheet first

    String? path;
    if (isFolder) {
      path = await FilePicker.getDirectoryPath();
    } else {
      FilePickerResult? r = await FilePicker.pickFiles();
      path = r?.files.single.path;
    }

    if (path != null) {
      cubit.setTargetIp(ip);
      cubit.sendData(path: path, isFolder: isFolder);
    }
  }
}

class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isDesktop;
  final VoidCallback onPressed;

  const _MenuButton({
    required this.icon,
    required this.text,
    required this.isDesktop,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedPressButton(
      isDesktop: isDesktop,
      onPressed: onPressed,
      gradientColors: const [AppColors.primary, AppColors.primaryLight],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 28.rx(isDesktop)),
          SizedBox(height: 5.rh(isDesktop)),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontSize: 13.rx(isDesktop),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
