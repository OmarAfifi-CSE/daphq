import '../models/transfer_model.dart';
import '../models/discovery_model.dart';
import '../core/app_constants.dart';

class AuthRequest {
  final String senderIp;
  final String senderName;
  final int fileCount;
  final double totalSizeMB;

  AuthRequest({
    required this.senderIp,
    required this.senderName,
    required this.fileCount,
    required this.totalSizeMB,
  });

  String get formattedSize {
    if (totalSizeMB >= 1024) {
      return "${(totalSizeMB / 1024).toStringAsFixed(2)} GB";
    } else {
      return "${totalSizeMB.toStringAsFixed(1)} MB";
    }
  }
}

class TransferState {
  final TransferModel model;
  final bool isTransferring;
  final bool isReceiving;
  final bool isReceivingActive;
  final bool isLastTransferIncoming;
  final String? receiveFolder;
  final String targetIp;

  // Discovery fields
  final List<DiscoveryModel> discoveredDevices;
  final String deviceName;
  final bool isAdvancedMode;

  // UI Feedback properties
  final String? errorMessage;
  final String? warningMessage;
  final bool showStorageSettingsDialog;
  final bool showNotificationWarningDialog;
  final bool showBatteryOptimizationSnackBar;
  final AuthRequest? authRequest;
  final List<String> selectedPaths;

  TransferState({
    required this.model,
    this.isTransferring = false,
    this.isReceiving = false,
    this.isReceivingActive = false,
    this.isLastTransferIncoming = false,
    this.receiveFolder,
    String? targetIp,
    this.discoveredDevices = const [],
    this.deviceName = 'Unknown Device',
    this.isAdvancedMode = false,
    this.errorMessage,
    this.warningMessage,
    this.showStorageSettingsDialog = false,
    this.showNotificationWarningDialog = false,
    this.showBatteryOptimizationSnackBar = false,
    this.authRequest,
    this.selectedPaths = const [],
  }) : targetIp = targetIp ?? AppConstants.defaultTargetIp;

  TransferState copyWith({
    TransferModel? model,
    bool? isTransferring,
    bool? isReceiving,
    bool? isReceivingActive,
    bool? isLastTransferIncoming,
    String? receiveFolder,
    String? targetIp,
    List<DiscoveryModel>? discoveredDevices,
    String? deviceName,
    bool? isAdvancedMode,
    String? errorMessage,
    String? warningMessage,
    bool? showStorageSettingsDialog,
    bool? showNotificationWarningDialog,
    bool? showBatteryOptimizationSnackBar,
    AuthRequest? authRequest,
    List<String>? selectedPaths,
    bool clearFeedback = false,
    bool clearAuthRequest = false,
    bool clearSelection = false,
  }) {
    return TransferState(
      model: model ?? this.model,
      isTransferring: isTransferring ?? this.isTransferring,
      isReceiving: isReceiving ?? this.isReceiving,
      isReceivingActive: isReceivingActive ?? this.isReceivingActive,
      isLastTransferIncoming:
          isLastTransferIncoming ?? this.isLastTransferIncoming,
      receiveFolder: receiveFolder ?? this.receiveFolder,
      targetIp: targetIp ?? this.targetIp,
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      deviceName: deviceName ?? this.deviceName,
      isAdvancedMode: isAdvancedMode ?? this.isAdvancedMode,
      errorMessage: clearFeedback ? null : (errorMessage ?? this.errorMessage),
      warningMessage: clearFeedback
          ? null
          : (warningMessage ?? this.warningMessage),
      showStorageSettingsDialog: clearFeedback
          ? false
          : (showStorageSettingsDialog ?? this.showStorageSettingsDialog),
      showNotificationWarningDialog: clearFeedback
          ? false
          : (showNotificationWarningDialog ??
                this.showNotificationWarningDialog),
      showBatteryOptimizationSnackBar: clearFeedback
          ? false
          : (showBatteryOptimizationSnackBar ??
                this.showBatteryOptimizationSnackBar),
      authRequest: clearAuthRequest ? null : (authRequest ?? this.authRequest),
      selectedPaths: clearSelection
          ? const []
          : (selectedPaths ?? this.selectedPaths),
    );
  }
}
