import '../models/transfer_model.dart';
import '../core/app_constants.dart';

class AuthRequest {
  final String senderIp;
  final int fileCount;
  final double totalSizeMB;

  AuthRequest({
    required this.senderIp,
    required this.fileCount,
    required this.totalSizeMB,
  });
}

class TransferState {
  final TransferModel model;
  final bool isTransferring;
  final bool isReceiving;
  final String? receiveFolder;
  final String targetIp;

  // UI Feedback properties
  final String? errorMessage;
  final String? warningMessage;
  final bool showStorageSettingsDialog;
  final bool showNotificationWarningDialog;
  final bool showBatteryOptimizationSnackBar;
  final AuthRequest? authRequest;

  TransferState({
    required this.model,
    this.isTransferring = false,
    this.isReceiving = false,
    this.receiveFolder,
    String? targetIp,
    this.errorMessage,
    this.warningMessage,
    this.showStorageSettingsDialog = false,
    this.showNotificationWarningDialog = false,
    this.showBatteryOptimizationSnackBar = false,
    this.authRequest,
  }) : targetIp = targetIp ?? AppConstants.defaultTargetIp;

  TransferState copyWith({
    TransferModel? model,
    bool? isTransferring,
    bool? isReceiving,
    String? receiveFolder,
    String? targetIp,
    String? errorMessage,
    String? warningMessage,
    bool? showStorageSettingsDialog,
    bool? showNotificationWarningDialog,
    bool? showBatteryOptimizationSnackBar,
    AuthRequest? authRequest,
    bool clearFeedback = false,
    bool clearAuthRequest = false,
  }) {
    return TransferState(
      model: model ?? this.model,
      isTransferring: isTransferring ?? this.isTransferring,
      isReceiving: isReceiving ?? this.isReceiving,
      receiveFolder: receiveFolder ?? this.receiveFolder,
      targetIp: targetIp ?? this.targetIp,
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
    );
  }
}
