import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import '../common/daphq_card.dart';
import '../common/animated_press_button.dart';
import '../common/custom_snackbar.dart';
import '../common/section_title.dart';
import '../common/status_text.dart';

class ReceiverSection extends StatelessWidget {
  final bool isDesktop;

  const ReceiverSection({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: AppConstants.receiverMode, isDesktop: isDesktop),
        SizedBox(height: 6.0.rh(isDesktop)),
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 8.rx(isDesktop),
                                  height: 8.rx(isDesktop),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: state.isReceiving ? AppColors.success : AppColors.danger,
                                    boxShadow: state.isReceiving ? [
                                      BoxShadow(
                                        color: AppColors.success.withAlpha(100),
                                        blurRadius: 4,
                                        spreadRadius: 2,
                                      )
                                    ] : null,
                                  ),
                                ),
                                SizedBox(width: 8.rw(isDesktop)),
                                Text(
                                  state.isReceiving ? AppConstants.readyToReceive : "Receiver Offline",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14.rx(isDesktop),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            SizedBox(height: 5.rh(isDesktop)),
                            StatusText(
                              text: state.receiveFolder == null
                                  ? AppConstants.noFolderSelected
                                  : "${AppConstants.saveToPrefix}${state.receiveFolder}",
                              isError: state.receiveFolder == null,
                              isDesktop: isDesktop,
                              tooltip: state.receiveFolder,
                            ),
                          ],
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
                  SizedBox(height: 12.0.rh(isDesktop)),
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
                          state.isReceiving ? Icons.stop : Icons.play_arrow,
                          color: state.isReceiving
                              ? Colors.white
                              : Colors.black87,
                          size: 20.0.rx(isDesktop),
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
                            fontSize: 14.0.rx(isDesktop),
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
