import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../controllers/sender_controller.dart';
import '../controllers/receiver_controller.dart';
import '../models/transfer_model.dart';
import '../views/widgets/auth_dialog.dart';
import 'transfer_state.dart';
import '../main.dart';
import 'dart:io';

class TransferCubit extends Cubit<TransferState> {
  final SenderController _sender = SenderController();
  final ReceiverController _receiver = ReceiverController();

  TransferCubit() : super(TransferState(model: TransferModel()));

  void _startForegroundService(String title, String text) {
    if (Platform.isAndroid) {
      FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: text,
        callback: startCallback,
      );
    }
  }

  void _stopForegroundService() {
    if (Platform.isAndroid) {
      FlutterForegroundTask.stopService();
    }
  }

  void setReceiveFolder(String path) {
    emit(state.copyWith(receiveFolder: path));
  }

  void setTargetIp(String ip) {
    emit(state.copyWith(targetIp: ip));
  }

  void stopReceiver() {
    _receiver.stop();
    _stopForegroundService();
    emit(
      state.copyWith(
        isReceiving: false,
        isTransferring: false,
        model: TransferModel(status: "Receiver Stopped"),
      ),
    );
  }

  Future<void> startReceiver({required BuildContext context}) async {
    if (state.receiveFolder == null) return;

    emit(state.copyWith(isReceiving: true, isTransferring: false));
    _startForegroundService("Turbo Transfer", "Waiting for incoming files...");

    _receiver.startReceiver(
      saveDirectory: state.receiveFolder!,
      onUpdate: (model) {
        bool isBusy = state.isTransferring;
        String s = model.status.toLowerCase();
        if (s.contains("ready & waiting") ||
            s.contains("complete") ||
            s.contains("cancelled") ||
            s.contains("error") ||
            s.contains("rejected")) {
          isBusy = false;
        } else if (s.contains("receiving data") || s.contains("connecting")) {
          isBusy = true;
        }

        if (!isClosed) {
          emit(state.copyWith(model: model, isTransferring: isBusy));
        }
        if (Platform.isAndroid) {
          FlutterForegroundTask.updateService(
            notificationTitle: 'Receiving: ${model.fileName}',
            notificationText:
                '${model.transferred.toStringAsFixed(2)} MB - ${model.status}',
          );
        }
      },
      onRequestAuth: (senderIp, count, size) => showAuthDialog(
        context: context,
        senderIp: senderIp,
        fileCount: count,
        totalSizeMB: size,
      ),
      onDone: () {
        if (Platform.isAndroid) {
          FlutterForegroundTask.updateService(
            notificationTitle: 'Turbo Transfer',
            notificationText: 'Receiver idle...',
          );
        }
      },
    );
  }

  Future<void> sendData({required String path, required bool isFolder}) async {
    if (state.isTransferring || state.targetIp.trim().isEmpty) return;

    emit(state.copyWith(isTransferring: true));
    _startForegroundService("Turbo Transfer", "Sending files...");

    _sender.sendData(
      path: path,
      targetIp: state.targetIp.trim(),
      isFolder: isFolder,
      onUpdate: (model) {
        if (!isClosed) emit(state.copyWith(model: model));
        if (Platform.isAndroid) {
          FlutterForegroundTask.updateService(
            notificationTitle: 'Sending: ${model.fileName}',
            notificationText:
                '${model.transferred.toStringAsFixed(2)} MB - ${model.status}',
          );
        }
      },
      onDone: () {
        if (!isClosed) emit(state.copyWith(isTransferring: false));
        _stopForegroundService();
      },
    );
  }

  @override
  Future<void> close() {
    _receiver.stop();
    _stopForegroundService();
    return super.close();
  }

  void cancelSending() {
    _sender.cancel();
    _stopForegroundService();
    emit(
      state.copyWith(
        isTransferring: false,
        model: TransferModel(status: "Transfer Cancelled"),
      ),
    );
  }
}
