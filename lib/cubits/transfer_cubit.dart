import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../controllers/sender_controller.dart';
import '../controllers/receiver_controller.dart';
import '../services/discovery_service.dart';
import 'package:file_picker/file_picker.dart';
import '../models/transfer_model.dart';
import 'transfer_state.dart';
import '../core/app_constants.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import '../main.dart';

class TransferCubit extends Cubit<TransferState> {
  final SenderController _sender = SenderController();
  final ReceiverController _receiver = ReceiverController();
  final DiscoveryService discoveryService = DiscoveryService();

  Completer<bool>? _authCompleter;
  Completer<bool>? _notifCompleter;
  StreamSubscription? _discoverySubscription;
  StreamSubscription? _connectivitySubscription;

  TransferCubit() : super(TransferState(model: TransferModel())) {
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    _initConnectivityListener();
    _initDiscovery();
    _startReceiverAutomatically();
  }

  void _initConnectivityListener() {
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
      results,
    ) async {
      if (isClosed) return;

      final List<ConnectivityResult> resultList = results;

      final bool isDisconnected =
          resultList.isNotEmpty &&
          resultList.every((r) => r == ConnectivityResult.none);

      if (isDisconnected) {
        if (state.isTransferring) {
          cancelSending(reason: "No network connection. Transfer cancelled.");
        }
      }

      // If receiver was active, restart it to bind to new IP
      if (state.isReceiving) {
        startReceiver();
      }
    });
  }

  DiscoveryService get discovery => discoveryService;

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

    _discoverySubscription = discoveryService.devicesStream.listen((devices) {
      if (!isClosed) {
        emit(state.copyWith(discoveredDevices: devices));
      }
    });

    discoveryService.startDiscovery(deviceName);
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
          defaultPath = p.join(downloadsDir.path, "Daphq");
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

    // Check Android version
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 30) {
      // Android 11+ uses Manage External Storage for folders
      if (await Permission.manageExternalStorage.isGranted) {
        hasStorage = true;
      } else {
        final status = await Permission.manageExternalStorage.request();
        hasStorage = status.isGranted;
        storagePermanentlyDenied = status.isPermanentlyDenied;
      }
    } else {
      // Older Androids use standard Storage permission
      if (await Permission.storage.isGranted) {
        hasStorage = true;
      } else {
        final status = await Permission.storage.request();
        hasStorage = status.isGranted;
        storagePermanentlyDenied = status.isPermanentlyDenied;
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
    // If receiver is already running, restart it with the new folder
    // but only if there is no active transfer happening right now.
    if (state.isReceiving && !state.isReceivingActive) {
      startReceiver();
    }
  }

  void setTargetIp(String ip) {
    emit(state.copyWith(targetIp: ip));
  }

  void clearFeedback() {
    emit(state.copyWith(clearFeedback: true));
  }

  void stopReceiver({String? reason}) {
    _receiver.stop(reason: reason);
    discoveryService.triggerBroadcast(
      isOnline: false,
    ); // Signal other devices to remove us instantly
    emit(
      state.copyWith(
        isReceiving: false,
        isReceivingActive: false,
        clearFeedback: true,
        model: TransferModel(
          status: reason ?? "Receiver Stopped",
          transferred: 0,
          totalSize: 0,
          progress: 0,
          fileName: "",
        ),
      ),
    );
    _stopForegroundService();
  }

  Future<void> startReceiver() async {
    if (state.receiveFolder == null) return;

    if (!await _prepareRequirements()) return;

    emit(state.copyWith(isReceiving: true, isTransferring: false));
    discoveryService.triggerBroadcast(); // Signal other devices immediately
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
      deviceName: state.deviceName,
      onUpdate: (model) {
        bool isBusy = false;
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
          emit(
            state.copyWith(
              model: model,
              isReceivingActive: isBusy,
              isLastTransferIncoming: isBusy
                  ? true
                  : state.isLastTransferIncoming,
            ),
          );
        }

        if (Platform.isAndroid && state.isReceiving) {
          String title = isBusy
              ? 'Receiving: ${model.fileName}'
              : AppConstants.appName;
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
      onRequestAuth: (senderIp, senderName, count, size) {
        _authCompleter = Completer<bool>();
        emit(
          state.copyWith(
            authRequest: AuthRequest(
              senderIp: senderIp,
              senderName: senderName,
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

        // Ensure UI reflects that receiver is no longer active
        if (!isClosed) {
          emit(state.copyWith(isReceiving: false, isReceivingActive: false));
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

  void addSelectedPaths(List<String> paths) {
    final newList = List<String>.from(state.selectedPaths)..addAll(paths);
    emit(state.copyWith(selectedPaths: newList));
  }

  void removeSelectedPath(String path) {
    final newList = List<String>.from(state.selectedPaths)..remove(path);
    emit(state.copyWith(selectedPaths: newList));
  }

  void clearSelection() {
    emit(state.copyWith(clearSelection: true));
  }

  Future<void> pickItems(FileType type) async {
    try {
      String? initialDirectory;

      // Smart folder opening for Desktop
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final home =
            Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
        if (home != null) {
          if (type == FileType.image) {
            initialDirectory = p.join(
              home,
              Platform.isWindows ? 'Pictures' : 'Pictures',
            );
          } else if (type == FileType.video) {
            initialDirectory = p.join(
              home,
              Platform.isWindows ? 'Videos' : 'Movies',
            );
          }
        }
      }

      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        type: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            ? FileType.any
            : type,
        initialDirectory: initialDirectory,
      );

      if (result != null) {
        addSelectedPaths(result.paths.whereType<String>().toList());
      }
    } catch (e) {
      emit(state.copyWith(errorMessage: "Error picking files: $e"));
    }
  }

  Future<void> pickFolder() async {
    try {
      final path = await FilePicker.getDirectoryPath();
      if (path != null) {
        addSelectedPaths([path]);
      }
    } catch (e) {
      emit(state.copyWith(errorMessage: "Error picking folder: $e"));
    }
  }

  Future<void> sendData({List<String>? paths}) async {
    final itemsToSend = paths ?? state.selectedPaths;
    if (itemsToSend.isEmpty ||
        state.isTransferring ||
        state.targetIp.trim().isEmpty) {
      return;
    }

    if (!await _prepareRequirements()) return;

    emit(state.copyWith(isTransferring: true, isLastTransferIncoming: false));

    await _startForegroundService(
      AppConstants.appName,
      "Sending files...",
      button: const NotificationButton(
        id: 'cancelSendingButton',
        text: 'Cancel Sending',
      ),
    );

    // Clear selection immediately so it doesn't pop back on error
    emit(state.copyWith(clearSelection: true));

    try {
      String targetDeviceName = "the other device";
      try {
        targetDeviceName = state.discoveredDevices
            .firstWhere((d) => d.ip == state.targetIp.trim())
            .name;
      } catch (_) {}

      await _sender.sendData(
        paths: itemsToSend,
        targetIp: state.targetIp.trim(),
        targetDeviceName: targetDeviceName,
        senderDeviceName: state.deviceName,
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
      );

      if (!isClosed) {
        emit(state.copyWith(isTransferring: false, clearFeedback: true));
      }

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
    } catch (e) {
      if (!isClosed) {
        emit(
          state.copyWith(
            isTransferring: false,
            errorMessage: e.toString(),
            model: TransferModel(
              status: "$e. Ready & Waiting...",
              transferred: state.model.transferred,
              totalSize: state.model.totalSize,
              progress: state.model.progress,
              fileName: state.model.fileName,
            ),
          ),
        );
      }
      if (!state.isReceiving) {
        _stopForegroundService();
      }
    }
  }

  @override
  Future<void> close() {
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    _discoverySubscription?.cancel();
    _connectivitySubscription?.cancel();
    discoveryService.stop();
    _receiver.stop();
    _stopForegroundService();
    return super.close();
  }

  void cancelSending({String? reason}) {
    _sender.cancel(reason: reason);
    emit(
      state.copyWith(
        isTransferring: false,
        clearFeedback: true,
        model: TransferModel(
          status: reason ?? "Transfer Cancelled",
          transferred: state.model.transferred,
          totalSize: state.model.totalSize,
          progress: state.model.progress,
          fileName: state.model.fileName,
        ),
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

  Future<void> openReceivedFolder() async {
    final folder = state.receiveFolder;
    if (folder == null) return;

    try {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final uri = Uri.file(folder);
        await launchUrl(uri);
      } else if (Platform.isAndroid) {
        // Use native MethodChannel for Android to avoid library issues
        const platform = MethodChannel('com.omarafifi.daphq/file_manager');
        await platform.invokeMethod('openFolder', {'path': folder});
      }
    } catch (e) {
      if (Platform.isAndroid) {
        emit(
          state.copyWith(
            errorMessage:
                "Could not open folder automatically. Please check: $folder",
          ),
        );
      } else {
        emit(state.copyWith(errorMessage: "Error opening folder: $e"));
      }
    }
  }
}
