import '../models/transfer_model.dart';
import '../models/discovery_model.dart';
import '../fabric/peer_models.dart';
import '../fabric/smart_link_evaluator.dart';
import '../security/trusted_devices_service.dart';
import '../core/app_constants.dart';

class AuthRequest {
  final String senderIp;
  final String senderName;
  final int fileCount;
  final double totalSizeMB;
  final String? senderPeerId;
  final String? senderFingerprint;
  final bool isTls;
  final bool isTrustedPeer;
  final bool isFingerprintMismatch;

  AuthRequest({
    required this.senderIp,
    required this.senderName,
    required this.fileCount,
    required this.totalSizeMB,
    this.senderPeerId,
    this.senderFingerprint,
    this.isTls = false,
    this.isTrustedPeer = false,
    this.isFingerprintMismatch = false,
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
  final bool showProgressView;

  // Discovery & Direct Fabric fields
  final List<DiscoveryModel> discoveredDevices;
  final List<UnifiedPeer> unifiedPeers;
  final List<TrustedDevice> trustedDevices;
  final String? localPeerId;
  final String? localFingerprint;
  final bool isDirectLinkConnecting;
  final String? directLinkStatus;
  final LocalRadioCapabilities? localRadioCapabilities;
  final String deviceName;

  // UI Feedback properties
  final String? errorMessage;
  final String? warningMessage;
  final bool showStorageSettingsDialog;
  final bool showNotificationWarningDialog;
  final bool showBatteryOptimizationSnackBar;
  final AuthRequest? authRequest;
  final List<String> selectedPaths;
  final Map<String, bool> selectedPathsIsDir;
  final bool isAddingFiles;
  final bool isLocatingFolder;

  TransferState({
    required this.model,
    this.isTransferring = false,
    this.isReceiving = false,
    this.isReceivingActive = false,
    this.isLastTransferIncoming = false,
    this.receiveFolder,
    String? targetIp,
    this.showProgressView = false,
    this.discoveredDevices = const [],
    this.unifiedPeers = const [],
    this.trustedDevices = const [],
    this.localPeerId,
    this.localFingerprint,
    this.isDirectLinkConnecting = false,
    this.directLinkStatus,
    this.localRadioCapabilities,
    this.deviceName = 'Unknown Device',
    this.errorMessage,
    this.warningMessage,
    this.showStorageSettingsDialog = false,
    this.showNotificationWarningDialog = false,
    this.showBatteryOptimizationSnackBar = false,
    this.authRequest,
    this.selectedPaths = const [],
    this.selectedPathsIsDir = const {},
    this.isAddingFiles = false,
    this.isLocatingFolder = true,
  }) : targetIp = targetIp ?? AppConstants.defaultTargetIp;

  TransferState copyWith({
    TransferModel? model,
    bool? isTransferring,
    bool? isReceiving,
    bool? isReceivingActive,
    bool? isLastTransferIncoming,
    String? receiveFolder,
    String? targetIp,
    bool? showProgressView,
    List<DiscoveryModel>? discoveredDevices,
    List<UnifiedPeer>? unifiedPeers,
    List<TrustedDevice>? trustedDevices,
    String? localPeerId,
    String? localFingerprint,
    bool? isDirectLinkConnecting,
    String? directLinkStatus,
    LocalRadioCapabilities? localRadioCapabilities,
    String? deviceName,
    String? errorMessage,
    String? warningMessage,
    bool? showStorageSettingsDialog,
    bool? showNotificationWarningDialog,
    bool? showBatteryOptimizationSnackBar,
    AuthRequest? authRequest,
    List<String>? selectedPaths,
    Map<String, bool>? selectedPathsIsDir,
    bool? isAddingFiles,
    bool? isLocatingFolder,
    bool clearFeedback = false,
    bool clearAuthRequest = false,
    bool clearSelection = false,
    bool clearDirectLinkStatus = false,
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
      showProgressView: showProgressView ?? this.showProgressView,
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      unifiedPeers: unifiedPeers ?? this.unifiedPeers,
      trustedDevices: trustedDevices ?? this.trustedDevices,
      localPeerId: localPeerId ?? this.localPeerId,
      localFingerprint: localFingerprint ?? this.localFingerprint,
      isDirectLinkConnecting:
          isDirectLinkConnecting ?? this.isDirectLinkConnecting,
      directLinkStatus: clearDirectLinkStatus
          ? null
          : (directLinkStatus ?? this.directLinkStatus),
      localRadioCapabilities:
          localRadioCapabilities ?? this.localRadioCapabilities,
      deviceName: deviceName ?? this.deviceName,
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
      selectedPathsIsDir: clearSelection
          ? const {}
          : (selectedPathsIsDir ?? this.selectedPathsIsDir),
      isAddingFiles: isAddingFiles ?? this.isAddingFiles,
      isLocatingFolder: isLocatingFolder ?? this.isLocatingFolder,
    );
  }
}
