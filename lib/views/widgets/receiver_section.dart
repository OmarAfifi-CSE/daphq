import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';

class ReceiverSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Receiver Mode", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),
        BlocBuilder<TransferCubit, TransferState>(
          builder: (context, state) {
            return Container(
              padding: EdgeInsets.all(15),
              decoration: BoxDecoration(color: Colors.white.withAlpha(12), borderRadius: BorderRadius.circular(15)),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.receiveFolder == null ? "No receive folder selected" : "Save to: ${state.receiveFolder}",
                          style: TextStyle(color: state.receiveFolder == null ? Colors.redAccent : Colors.greenAccent),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.folder_open, color: Colors.white),
                        onPressed: state.isTransferring ? null : () async {
                          String? path = await FilePicker.getDirectoryPath();
                          if (path != null) {
                            context.read<TransferCubit>().setReceiveFolder(path);
                          }
                        },
                      )
                    ],
                  ),
                  SizedBox(height: 15),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: state.isReceiving ? Colors.red : Colors.green,
                      minimumSize: Size(double.infinity, 50),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                    ),
                    onPressed: state.isTransferring && !state.isReceiving ? null : () {
                      if (state.isReceiving) {
                        context.read<TransferCubit>().stopReceiver();
                      } else {
                        if (state.receiveFolder == null) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Please select a receive folder first!")));
                          return;
                        }
                        context.read<TransferCubit>().startReceiver(context: context);
                      }
                    },
                    icon: Icon(state.isReceiving ? Icons.stop : Icons.wifi_tethering, color: Colors.white),
                    label: Text(state.isReceiving ? "Stop Receiver" : "Start Receiver Server", style: TextStyle(color: Colors.white, fontSize: 16)),
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
