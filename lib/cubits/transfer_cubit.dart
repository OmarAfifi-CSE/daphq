import 'dart:async';
import 'dart:io';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../controllers/sender_controller.dart';
import '../controllers/receiver_controller.dart';
import '../services/discovery_service.dart';
import '../models/transfer_model.dart';
import 'transfer_state.dart';
import '../core/app_constants.dart';
import '../main.dart';

class TransferCubit extends Cubit<TransferState> {
  final SenderController _sender = SenderController();
  final ReceiverController _receiver = ReceiverController();
  final DiscoveryService _discovery = DiscoveryService();

  Completer<bool>? _authCompleter;
  Completer<bool>? _notifCompleter;
  StreamSubscription? _discoverySubscription;

  TransferCubit() : super(TransferState(model: TransferModel())) {
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _initDiscovery();
    _startReceiverAutomatically();
  }

  Future<void> _initDiscovery() async {
    String deviceName = 'Unknown Device';
    final deviceInfo = DeviceInfoPlugin();

    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        deviceName = "${androidInfo.manufacturer} ${androidInfo.model}";
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        deviceName = windowsInfo.computerName;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        deviceName = iosInfo.name;
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        deviceName = macInfo.computerName;
      } else {
        deviceName = Platform.localHostname;
      }
    } catch (_) {
      deviceName = Platform.localHostname;
    }

    emit(state.copyWith(deviceName: deviceName));
    
    _discoverySubscription = _discovery.devicesStream.listen((devices) {
      if (!isClosed) {
        emit(state.copyWith(discoveredDevices: devices));
      }
    });

    _discovery.startDiscovery(deviceName);
  }

  Future<void> _startReceiverAutomatically() async {
    // Wait a bit for permissions to be handled in main.dart or _prepareRequirements
    await Future.delayed(const Duration(milliseconds: 1500));
    
    if (state.isReceiving) return;

    String? defaultPath;
    try {
      if (Platform.isAndroid) {
        // Use external storage downloads
        defaultPath = "/storage/emulated/0/Download/Daphq";
      } else {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          defaultPath = Directory("${downloadsDir.path}/Daphq").path;
        }
      }
    } catch (_) {}

    if (defaultPath != null) {
      setReceiveFolder(defaultPath);
      startReceiver();
    }
  }

  void toggleAdvancedMode() {
    emit(state.copyWith(isAdvancedMode: !state.isAdvancedMode));
  }

  void _onReceiveTaskData(dynamic message) {
    if (message == 'stopReceivingButton') {
      stopReceiver();
    } else if (message == 'cancelSendingButton') {
      cancelSending();
    }
  }

  Future<bool> _prepareRequirements() async {
    if (!Platform.isAndroid) return true;

    bool showedWarning = false;

    // 0. Storage Permission Check
    bool hasStorage = false;
    bool storagePermanentlyDenied = false;

    if (await Permission.manageExternalStorage.isGranted ||
        await Permission.storage.isGranted) {
      hasStorage = true;
    } else {
      final manageStatus = await Permission.manageExternalStorage.request();
      if (manageStatus.isGranted) {
        hasStorage = true;
      } else {
        final storageStatus = await Permission.storage.request();
        if (storageStatus.isGranted) {
          hasStorage = true;
        } else {
          storagePermanentlyDenied =
              manageStatus.isPermanentlyDenied ||
              storageStatus.isPermanentlyDenied;
        }
      }
    }

    if (!hasStorage) {
      if (storagePermanentlyDenied) {
        emit(state.copyWith(showStorageSettingsDialog: true));
        return false;
      } else {
        emit(
          state.copyWith(
            errorMessage:
                "Error: Storage permission is strictly required to transfer files.",
          ),
        );
        return false;
      }
    }

    // 1. Notification Permission Check
    PermissionStatus notifStatus = await Permission.notification.status;
    if (notifStatus.isDenied) {
      notifStatus = await Permission.notification.request();
    }

    if (notifStatus.isPermanentlyDenied) {
      _notifCompleter = Completer<bool>();
      emit(state.copyWith(showNotificationWarningDialog: true));
      bool proceed = await _notifCompleter!.future;
      if (!proceed) return false;
      showedWarning = true;
      emit(
        state.copyWith(
          errorMessage:
              "Warning: Transfer may stop if minimized without notifications.",
        ),
      );
    } else if (!notifStatus.isGranted &&
        notifStatus != PermissionStatus.permanentlyDenied) {
      return false;
    }

    // 2. Battery Optimization Check (Fire-and-forget Async to prevent blocking transfer init)
    _triggerBatteryCheck(showedWarning);
    return true;
  }
// ... rest of the file

  Future<void> _triggerBatteryCheck(bool showedWarning) async {
    bool isIgnoring = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!isIgnoring) {
      final delay = showedWarning
          ? const Duration(milliseconds: 4500)
          : const Duration(milliseconds: 500);
      await Future.delayed(delay);

      if (isClosed || (!state.isReceiving && !state.isTransferring)) {
        return;
      }

      emit(state.copyWith(showBatteryOptimizationSnackBar: true));
    }
  }

  Future<void> _startForegroundService(
    String title,
    String text, {
    NotificationButton? button,
  }) async {
    if (Platform.isAndroid) {
      final safeTitle = title.isEmpty ? AppConstants.appName : title;
      final safeText = text.isEmpty ? "Running..." : text;

      await FlutterForegroundTask.startService(
        notificationTitle: safeTitle,
        notificationText: safeText,
        callback: startCallback,
        serviceId: AppConstants.foregroundServiceId,
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.pravera.flutter_foreground_task.notification_icon',
        ),
        notificationButtons: button != null ? [button] : null,
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

  void clearFeedback() {
    emit(state.copyWith(clearFeedback: true));
  }

  void stopReceiver() {
    _receiver.stop();
    _discovery.triggerBroadcast(isOnline: false); // Signal other devices to remove us instantly
    emit(
      state.copyWith(
        isReceiving: false,
        isTransferring: false,
        clearFeedback: true,
        model: TransferModel(status: "Receiver Stopped"),
      ),
    );
    _stopForegroundService();
  }

  Future<void> startReceiver() async {
    if (state.receiveFolder == null) return;

    if (!await _prepareRequirements()) return;

    emit(state.copyWith(isReceiving: true, isTransferring: false));
    _discovery.triggerBroadcast(); // Signal other devices immediately
    await _startForegroundService(
      AppConstants.appName,
      "Waiting for incoming files...",
      button: const NotificationButton(
        id: 'stopReceivingButton',
        text: 'Stop Receiving',
      ),
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
        
        if (Platform.isAndroid && state.isReceiving) {
          String title = isBusy ? 'Receiving: ${model.fileName}' : AppConstants.appName;
          String text = isBusy 
              ? '${model.transferred.toStringAsFixed(2)} MB (${(model.progress * 100).toInt()}%) - ${model.speed.toStringAsFixed(1)} MB/s'
              : model.status;
          
          FlutterForegroundTask.updateService(
            notificationTitle: title,
            notificationText: text,
            notificationButtons: [
              const NotificationButton(
                id: 'stopReceivingButton',
                text: 'Stop Receiving',
              ),
            ],
          );
        }
      },
      onRequestAuth: (senderIp, count, size) {
        _authCompleter = Completer<bool>();
        emit(
          state.copyWith(
            authRequest: AuthRequest(
              senderIp: senderIp,
              fileCount: count,
              totalSizeMB: size,
            ),
          ),
        );
        return _authCompleter!.future;
      },
      onDone: () {
        if (Platform.isAndroid) {
          FlutterForegroundTask.updateService(
            notificationTitle: AppConstants.appName,
            notificationText: 'Receiver idle...',
          );
        }
      },
    );
  }

  void resolveAuth(bool accept) {
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(accept);
    }
    emit(state.copyWith(clearAuthRequest: true));
  }

  void resolveNotificationWarning(bool proceed) {
    if (_notifCompleter != null && !_notifCompleter!.isCompleted) {
      _notifCompleter!.complete(proceed);
    }
    emit(state.copyWith(clearFeedback: true));
  }

  Future<void> sendData({required String path, required bool isFolder}) async {
    if (state.isTransferring || state.targetIp.trim().isEmpty) return;

    if (!await _prepareRequirements()) return;

    emit(state.copyWith(isTransferring: true));
    await _startForegroundService(
      AppConstants.appName,
      "Sending files...",
      button: const NotificationButton(
        id: 'cancelSendingButton',
        text: 'Cancel Sending',
      ),
    );

    _sender.sendData(
      path: path,
      targetIp: state.targetIp.trim(),
      isFolder: isFolder,
      onUpdate: (model) {
        if (!isClosed) emit(state.copyWith(model: model));
        if (Platform.isAndroid && state.isTransferring) {
          FlutterForegroundTask.updateService(
            notificationTitle: 'Sending: ${model.fileName}',
            notificationText:
                '${model.transferred.toStringAsFixed(2)} MB (${(model.progress * 100).toInt()}%) - ${model.speed.toStringAsFixed(1)} MB/s',
            notificationButtons: [
              const NotificationButton(
                id: 'cancelSendingButton',
                text: 'Cancel Sending',
              ),
            ],
          );
        }
      },
      onDone: () {
        if (!isClosed) {
          emit(state.copyWith(isTransferring: false, clearFeedback: true));
        }
        
        if (state.isReceiving) {
          // Keep service alive but update to idle receiver status
          if (Platform.isAndroid) {
            FlutterForegroundTask.updateService(
              notificationTitle: AppConstants.appName,
              notificationText: "Waiting for incoming files...",
              notificationButtons: [
                const NotificationButton(
                  id: 'stopReceivingButton',
                  text: 'Stop Receiving',
                ),
              ],
            );
          }
        } else {
          _stopForegroundService();
        }
      },
    );
  }

  @override
  Future<void> close() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    _discoverySubscription?.cancel();
    _discovery.stop();
    _receiver.stop();
    _stopForegroundService();
    return super.close();
  }

  void cancelSending() {
    _sender.cancel();
    emit(
      state.copyWith(
        isTransferring: false,
        clearFeedback: true,
        model: TransferModel(status: "Transfer Cancelled"),
      ),
    );
    if (state.isReceiving) {
      if (Platform.isAndroid) {
        FlutterForegroundTask.updateService(
          notificationTitle: AppConstants.appName,
          notificationText: "Waiting for incoming files...",
          notificationButtons: [
            const NotificationButton(
              id: 'stopReceivingButton',
              text: 'Stop Receiving',
            ),
          ],
        );
      }
    } else {
      _stopForegroundService();
    }
  }
}
