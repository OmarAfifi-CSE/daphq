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
import 'package:permission_handler/permission_handler.dart';
import '../core/app_colors.dart';

class TransferCubit extends Cubit<TransferState> {
  final SenderController _sender = SenderController();
  final ReceiverController _receiver = ReceiverController();
  BuildContext? _lastContext;

  TransferCubit() : super(TransferState(model: TransferModel())) {
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
  }

  void _onReceiveTaskData(dynamic message) {
    print('TransferCubit._onReceiveTaskData received: $message');
    if (message == 'STOP') {
      stopReceiver();
      cancelSending();
    }
  }

  Future<bool> _prepareRequirements(BuildContext context) async {
    _lastContext = context;
    if (!Platform.isAndroid) return true;

    // Capture the ScaffoldMessengerState synchronously to prevent async unmounting issues
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    bool showedWarning = false;

    // 1. Notification Permission Check
    PermissionStatus notifStatus = await Permission.notification.status;
    if (notifStatus.isDenied) {
      notifStatus = await Permission.notification.request();
    }

    if (notifStatus.isPermanentlyDenied && context.mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.dialogBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          content: const Text(
            "Notifications are required to keep the transfer alive in the background. Please enable them in Settings.",
            style: TextStyle(color: Colors.white),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.white70),
              ),
            ),
            TextButton(
              onPressed: () {
                openAppSettings();
                Navigator.pop(dialogContext, true);
              },
              child: const Text(
                "Open Settings",
                style: TextStyle(color: Colors.blue),
              ),
            ),
          ],
        ),
      );

      if (proceed == false) {
        showedWarning = true;
        scaffoldMessenger.clearSnackBars();
        scaffoldMessenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF1E1E2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            margin: const EdgeInsets.all(12),
            content: const Text(
              "Warning: Transfer may stop if the app is minimized without notifications.",
              style: TextStyle(color: Colors.white),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      } else if (proceed == true) {
        return false;
      }
    } else if (!notifStatus.isGranted &&
        notifStatus != PermissionStatus.permanentlyDenied) {
      return false;
    }

    // 2. Battery Optimization Check (Fire-and-forget Aysnc to prevent blocking transfer init)
    _triggerBatteryCheck(showedWarning, scaffoldMessenger);
    return true;
  }

  Future<void> _triggerBatteryCheck(
    bool showedWarning,
    ScaffoldMessengerState scaffoldMessenger,
  ) async {
    bool isIgnoring = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!isIgnoring) {
      // If warning shown (duration 5s), wait 5.5s to show battery check exactly after it fades
      // Otherwise, delay slightly (0.5s) for visual separation from system dialogs
      final delay = showedWarning
          ? const Duration(milliseconds: 5500)
          : const Duration(milliseconds: 500);
      await Future.delayed(delay);

      scaffoldMessenger.clearSnackBars();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1E1E2E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          margin: const EdgeInsets.all(12),
          content: const Text(
            "For faster speeds and stable background transfer, consider disabling battery optimization.",
            style: TextStyle(color: Colors.white),
          ),
          action: SnackBarAction(
            label: "DISABLE",
            textColor: Colors.indigoAccent,
            onPressed: () async {
              await Permission.ignoreBatteryOptimizations.request();
            },
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _dismissSnackbar() {
    if (_lastContext != null && _lastContext!.mounted) {
      ScaffoldMessenger.of(_lastContext!).hideCurrentSnackBar();
    }
  }

  Future<void> _startForegroundService(String title, String text) async {
    if (Platform.isAndroid) {
      final safeTitle = title.isEmpty ? "Turbo Transfer" : title;
      final safeText = text.isEmpty ? "Running..." : text;

      print('Service Start Attempted');
      final result = await FlutterForegroundTask.startService(
        notificationTitle: safeTitle,
        notificationText: safeText,
        callback: startCallback,
        serviceId: 100,
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
        ),
        notificationButtons: [
          const NotificationButton(id: 'stopButton', text: 'Stop/Cancel'),
        ],
      );
      print('Service Result: ${result is ServiceRequestSuccess}');
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
    _dismissSnackbar();
    _receiver.stop();
    emit(
      state.copyWith(
        isReceiving: false,
        isTransferring: false,
        model: TransferModel(status: "Receiver Stopped"),
      ),
    );
    _stopForegroundService();
  }

  Future<void> startReceiver({required BuildContext context}) async {
    if (state.receiveFolder == null) return;

    if (!await _prepareRequirements(context)) return;

    emit(state.copyWith(isReceiving: true, isTransferring: false));
    await _startForegroundService(
      "Turbo Transfer",
      "Waiting for incoming files...",
    );

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
          String speedStr = model.speed > 0
              ? '${model.speed.toStringAsFixed(1)} MB/s'
              : '';
          FlutterForegroundTask.updateService(
            notificationTitle: 'Receiving: ${model.fileName}',
            notificationText:
                '${model.transferred.toStringAsFixed(2)} MB $speedStr - ${model.status}',
            notificationButtons: [
              const NotificationButton(id: 'stopButton', text: 'Stop/Cancel'),
            ],
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

  Future<void> sendData({
    required BuildContext context,
    required String path,
    required bool isFolder,
  }) async {
    if (state.isTransferring || state.targetIp.trim().isEmpty) return;

    if (!await _prepareRequirements(context)) return;

    emit(state.copyWith(isTransferring: true));
    await _startForegroundService("Turbo Transfer", "Sending files...");

    _sender.sendData(
      path: path,
      targetIp: state.targetIp.trim(),
      isFolder: isFolder,
      onUpdate: (model) {
        if (!isClosed) emit(state.copyWith(model: model));
        if (Platform.isAndroid) {
          String speedStr = model.speed > 0
              ? '${model.speed.toStringAsFixed(1)} MB/s'
              : '';
          FlutterForegroundTask.updateService(
            notificationTitle: 'Sending: ${model.fileName}',
            notificationText:
                '${model.transferred.toStringAsFixed(2)} MB $speedStr - ${model.status}',
            notificationButtons: [
              const NotificationButton(id: 'stopButton', text: 'Stop/Cancel'),
            ],
          );
        }
      },
      onDone: () {
        if (!isClosed) emit(state.copyWith(isTransferring: false));
        _dismissSnackbar();
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
    _dismissSnackbar();
    _sender.cancel();
    emit(
      state.copyWith(
        isTransferring: false,
        model: TransferModel(status: "Transfer Cancelled"),
      ),
    );
    _stopForegroundService();
  }
}
