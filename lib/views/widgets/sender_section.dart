import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';
import '../../core/app_colors.dart';
import '../../core/responsive_utils.dart';

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
          builder: (context, state) {
            return Container(
              padding: EdgeInsets.all(15.0.rw(isDesktop)),
              decoration: BoxDecoration(
                color: AppColors.cardOverlay,
                borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
              ),
              child: Column(
                children: [
                  TextField(
                    controller: _ipController,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14.0.rx(isDesktop),
                    ),
                    decoration: InputDecoration(
                      labelText: "Receiver IP Address (e.g. 192.168.x.x)",
                      labelStyle: TextStyle(
                        color: Colors.white38,
                        fontSize: 14.0.rx(isDesktop),
                      ),
                      helperText: "Please update this to the exact Receiver IP",
                      helperStyle: TextStyle(
                        color: Colors.white60,
                        fontStyle: FontStyle.italic,
                        fontSize: 12.0.rx(isDesktop),
                      ),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24),
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
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        minimumSize: Size(double.infinity, 50.0.rh(isDesktop)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            15.0.rr(isDesktop),
                          ),
                        ),
                      ),
                      onPressed: () {
                        context.read<TransferCubit>().cancelSending();
                      },
                      icon: Icon(
                        Icons.cancel,
                        color: Colors.white,
                        size: 24.0.rx(isDesktop),
                      ),
                      label: Text(
                        "Cancel Transfer",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16.0.rx(isDesktop),
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

  Widget _buildSendButton(
    BuildContext context,
    IconData icon,
    String text,
    bool isFolder,
    TransferState state,
    bool isDesktop,
  ) {
    return ElevatedButton.icon(
      onPressed: state.isTransferring ? null : () => _pick(context, isFolder),
      icon: Icon(icon, color: Colors.white, size: 20.0.rx(isDesktop)),
      label: Text(
        text,
        style: TextStyle(color: Colors.white, fontSize: 14.0.rx(isDesktop)),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blueAccent,
        minimumSize: Size(0, 50.0.rh(isDesktop)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
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
