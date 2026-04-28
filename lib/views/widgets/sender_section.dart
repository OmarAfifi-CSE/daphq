import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';
import '../../core/app_colors.dart';
import '../../core/responsive_utils.dart';
import 'daphq_card.dart';
import 'animated_press_button.dart';

class SenderSection extends StatefulWidget {
  final bool isDesktop;

  const SenderSection({super.key, this.isDesktop = false});

  @override
  SenderSectionState createState() => SenderSectionState();
}

class SenderSectionState extends State<SenderSection> {
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
    final isDesktop = widget.isDesktop;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Sender Mode",
          style: TextStyle(
            color: Colors.white,
            fontSize: 20.0.rx(isDesktop),
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 10.0.rh(isDesktop)),
        BlocBuilder<TransferCubit, TransferState>(
          buildWhen: (previous, current) =>
              previous.isTransferring != current.isTransferring ||
              previous.isReceiving != current.isReceiving ||
              previous.targetIp != current.targetIp,
          builder: (context, state) {
            return DaphqCard(
              isDesktop: isDesktop,
              child: Column(
                children: [
                  TextField(
                    controller: _ipController,
                    cursorColor: AppColors.primary,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14.0.rx(isDesktop),
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      labelText: "Receiver IP Address (e.g. 192.168.x.x)",
                      labelStyle: TextStyle(
                        color: Colors.white60,
                        fontSize: 14.0.rx(isDesktop),
                      ),
                      helperText: "Please update this to the exact Receiver IP",
                      helperStyle: TextStyle(
                        color: Colors.white38,
                        fontStyle: FontStyle.italic,
                        fontSize: 12.0.rx(isDesktop),
                      ),
                      filled: true,
                      fillColor: Colors.black.withAlpha(50),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10.0.rr(isDesktop)),
                        borderSide: const BorderSide(color: Colors.white12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10.0.rr(isDesktop)),
                        borderSide: const BorderSide(color: AppColors.primary),
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10.0.rr(isDesktop)),
                        borderSide: const BorderSide(color: Colors.white10),
                      ),
                    ),
                    enabled: !state.isTransferring,
                  ),
                  SizedBox(height: 20.0.rh(isDesktop)),
                  Row(
                    children: [
                      Expanded(
                        child: _buildSendButton(
                          context,
                          Icons.file_copy,
                          "Send File",
                          false,
                          state,
                          isDesktop,
                        ),
                      ),
                      SizedBox(width: 15.0.rw(isDesktop)),
                      Expanded(
                        child: _buildSendButton(
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
                    SizedBox(height: 15.0.rh(isDesktop)),
                    AnimatedPressButton(
                      isDesktop: isDesktop,
                      onPressed: () {
                        context.read<TransferCubit>().cancelSending();
                      },
                      gradientColors: const [
                        AppColors.danger,
                        Color(0xFFE57373),
                      ],
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.cancel,
                            color: Colors.white,
                            size: 24.0.rx(isDesktop),
                          ),
                          SizedBox(width: 8.0.rw(isDesktop)),
                          Text(
                            "Cancel Transfer",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16.0.rx(isDesktop),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
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

  Widget _buildSendButton(
    BuildContext context,
    IconData icon,
    String text,
    bool isFolder,
    TransferState state,
    bool isDesktop,
  ) {
    return AnimatedPressButton(
      isDesktop: isDesktop,
      onPressed: state.isTransferring ? null : () => _pick(context, isFolder),
      gradientColors: const [AppColors.primary, Color(0xFF64B5F6)],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 20.0.rx(isDesktop)),
          SizedBox(width: 8.0.rw(isDesktop)),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: 14.0.rx(isDesktop),
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please enter target IP!")),
        );
        return;
      }
      if (!context.mounted) return;
      cubit.sendData(context: context, path: path, isFolder: isFolder);
    }
  }
}
