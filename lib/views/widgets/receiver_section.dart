import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';
import '../../core/app_colors.dart';
import '../../core/app_constants.dart';
import '../../core/responsive_utils.dart';
import 'daphq_card.dart';
import 'animated_press_button.dart';
import 'custom_snackbar.dart';
import 'section_title.dart';
import 'status_text.dart';

class ReceiverSection extends StatelessWidget {
  final bool isDesktop;

  const ReceiverSection({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: AppConstants.receiverMode, isDesktop: isDesktop),
        SizedBox(height: 10.0.rh(isDesktop)),
        BlocBuilder<TransferCubit, TransferState>(
          buildWhen: (previous, current) =>
              previous.isReceiving != current.isReceiving ||
              previous.isTransferring != current.isTransferring ||
              previous.receiveFolder != current.receiveFolder,
          builder: (context, state) {
            return DaphqCard(
              isDesktop: isDesktop,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: StatusText(
                          text: state.receiveFolder == null
                              ? AppConstants.noFolderSelected
                              : "${AppConstants.saveToPrefix}${state.receiveFolder}",
                          isError: state.receiveFolder == null,
                          isDesktop: isDesktop,
                          tooltip: state.receiveFolder,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.folder_open,
                          color: Colors.white,
                          size: 24.0.rx(isDesktop),
                        ),
                        onPressed: state.isTransferring
                            ? null
                            : () async {
                                String? path =
                                    await FilePicker.getDirectoryPath();
                                if (path != null) {
                                  if (context.mounted) {
                                    context
                                        .read<TransferCubit>()
                                        .setReceiveFolder(path);
                                  }
                                }
                              },
                      ),
                    ],
                  ),
                  SizedBox(height: 15.0.rh(isDesktop)),
                  AnimatedPressButton(
                    isDesktop: isDesktop,
                    onPressed: state.isTransferring && !state.isReceiving
                        ? null
                        : () {
                            if (state.isReceiving) {
                              CustomSnackBar.hide();
                              context.read<TransferCubit>().stopReceiver();
                            } else {
                              if (state.receiveFolder == null) {
                                CustomSnackBar.show(
                                  context,
                                  message: AppConstants.selectFolderFirst,
                                );
                                return;
                              }
                              context.read<TransferCubit>().startReceiver();
                            }
                          },
                    gradientColors: state.isReceiving
                        ? const [AppColors.danger, AppColors.dangerLight]
                        : const [AppColors.success, AppColors.successLight],
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          state.isReceiving ? Icons.stop : Icons.wifi_tethering,
                          color: state.isReceiving
                              ? Colors.white
                              : Colors.black87,
                          size: 24.0.rx(isDesktop),
                        ),
                        SizedBox(width: 8.0.rw(isDesktop)),
                        Text(
                          state.isReceiving
                              ? AppConstants.stopReceiver
                              : AppConstants.startReceiver,
                          style: TextStyle(
                            color: state.isReceiving
                                ? Colors.white
                                : Colors.black87,
                            fontSize: 16.0.rx(isDesktop),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
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
