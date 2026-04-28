import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';
import '../../core/app_colors.dart';
import '../../core/responsive_utils.dart';
import 'daphq_card.dart';

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
            fontSize: 20.0.rx(isDesktop),
            fontWeight: FontWeight.bold,
          ),
        ),
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
                              fontSize: 14.0.rx(isDesktop),
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
                          size: 24.0.rx(isDesktop),
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
                  SizedBox(height: 15.0.rh(isDesktop)),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isReceiving
                          ? Colors.red
                          : Colors.green,
                      minimumSize: Size(double.infinity, 50.0.rh(isDesktop)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
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
                                  const SnackBar(
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
                      size: 24.0.rx(isDesktop),
                    ),
                    label: Text(
                      state.isReceiving
                          ? "Stop Receiver"
                          : "Start Receiver Server",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16.0.rx(isDesktop),
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
