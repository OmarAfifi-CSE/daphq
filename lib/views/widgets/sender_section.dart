import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';
import 'package:flutter/foundation.dart';

class SenderSection extends StatefulWidget {
  @override
  _SenderSectionState createState() => _SenderSectionState();
}

class _SenderSectionState extends State<SenderSection> {
  late final TextEditingController _ipController;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(text: context.read<TransferCubit>().state.targetIp);
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Sender Mode", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),
        BlocBuilder<TransferCubit, TransferState>(
          builder: (context, state) {
            return Container(
              padding: EdgeInsets.all(15),
              decoration: BoxDecoration(color: Colors.white.withAlpha(12), borderRadius: BorderRadius.circular(15)),
              child: Column(
                children: [
                  TextField(
                    controller: _ipController,
                    style: TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: labelHint,
                      labelStyle: TextStyle(color: Colors.white38),
                      helperText: "Please update this to the exact Receiver IP",
                      helperStyle: TextStyle(color: Colors.white60, fontStyle: FontStyle.italic),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    ),
                    enabled: !state.isTransferring,
                  ),
                  SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(child: _btn(context, Icons.file_copy, "Send File", false, state)),
                      SizedBox(width: 15),
                      Expanded(child: _btn(context, Icons.folder, "Send Folder", true, state)),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _btn(BuildContext context, IconData icon, String text, bool isFolder, TransferState state) {
    return ElevatedButton.icon(
      onPressed: state.isTransferring ? null : () => _pick(context, isFolder),
      icon: Icon(icon, color: Colors.white),
      label: Text(text, style: TextStyle(color: Colors.white)),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blueAccent,
        minimumSize: Size(0, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Please enter target IP!")));
        return;
      }
      cubit.sendData(path: path, isFolder: isFolder);
    }
  }
}
