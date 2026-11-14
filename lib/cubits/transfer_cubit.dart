import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../controllers/sender_controller.dart';
import '../controllers/receiver_controller.dart';
import '../controllers/v2_protocol_framing.dart' show generateTransferSessionId;
import '../services/discovery_service.dart';
import '../services/history_service.dart';
import 'package:file_picker/file_picker.dart';
import '../models/transfer_model.dart';
import '../fabric/ble_beacon_codec.dart';
import '../fabric/direct_native_bridge.dart';
import '../fabric/peer_models.dart';
import '../fabric/peer_registry.dart';
import '../fabric/smart_link_evaluator.dart';
import '../security/device_identity_service.dart';
import '../security/trusted_devices_service.dart';
import 'transfer_state.dart';
import '../core/app_constants.dart';
import 'package:flutter/services.dart';
import '../services/native_share_service.dart';
import '../main.dart';

class TransferCubit extends Cubit<TransferState> {
  final SenderController _sender;
  final ReceiverController _receiver;
  final DiscoveryService discoveryService;
  final DeviceIdentityService _identityService;
  final TrustedDevicesService _trustedDevicesService;
  final DirectNativeBridge _directBridge;
  final SmartLinkEvaluator _linkEvaluator;
  final PeerRegistry _peerRegistry;

  Completer<bool>? _authCompleter;
  TransferAuthRequest? _pendingAuthV2Request;
  Completer<bool>? _notifCompleter;
  StreamSubscription? _discoverySubscription;
  StreamSubscription? _heartbeatSubscription;
  StreamSubscription? _directEventsSubscription;
  StreamSubscription? _peersSubscription;
  StreamSubscription? _connectivitySubscription;
  Timer? _peerPruneTimer;
  bool _isStartingReceiver = false;
  int _receiverSessionSeq = 0;
  bool _isPreparingSend = false;
  int _sendSessionToken = 0;
  Future<void> _receiverUpdateChain = Future<void>.value();

  DeviceIdentity? _localIdentity;
  LocalRadioCapabilities? _localRadioCaps;
  PeerCapabilities _localPeerCaps = const PeerCapabilities();
  final Set<String> _activeLanIps = <String>{};
  Completer<DirectGattLinkRequestEvent>? _pendingHostReadyCompleter;
  String? _pendingHostReadyPeerId;
  String? _pendingHostReadyRequestId;
  String? _pendingHostReadyExpectedFp;
  String? _pendingHostReadyExpectedFpPrefix;
  bool _activeHostedDirectSession = false;
  bool _isStartingHostedDirect = false;
  Timer? _hostedDirectWatchdogTimer;

  void _safeEmit(TransferState nextState) {
    if (!isClosed) {
      emit(nextState);
    }
  }

  TransferCubit({
    SenderController? sender,
    ReceiverController? receiver,
    DiscoveryService? discoveryService,
    DeviceIdentityService? identityService,
    TrustedDevicesService? trustedDevicesService,
    DirectNativeBridge? directBridge,
    SmartLinkEvaluator? linkEvaluator,
    PeerRegistry? peerRegistry,
    bool autoStart = true,
  }) : _sender = sender ?? SenderController(),
       _receiver = receiver ?? ReceiverController(),
       discoveryService = discoveryService ?? DiscoveryService(),
       _identityService = identityService ?? DeviceIdentityService(),
       _trustedDevicesService =
           trustedDevicesService ?? TrustedDevicesService(),
       _directBridge = directBridge ?? DirectNativeBridge(),
       _linkEvaluator = linkEvaluator ?? const SmartLinkEvaluator(),
       _peerRegistry = peerRegistry ?? PeerRegistry(),
       super(TransferState(model: TransferModel())) {
    _bindPeerStreams();
    if (autoStart) {
      if (Platform.isAndroid) {
        FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
      }
      _initConnectivityListener();
      _initDiscovery();
      _startReceiverAutomatically();
    }
  }

  void _bindPeerStreams() {
    _peersSubscription = _peerRegistry.peersStream.listen((peers) {
      if (isClosed) return;
      final models = peers
          .map((p) => p.toDiscoveryModel())
          .toList(growable: false);
      emit(state.copyWith(unifiedPeers: peers, discoveredDevices: models));
    });

    _directEventsSubscription = _directBridge.events.listen(
      _handleDirectFabricEvent,
    );

    _heartbeatSubscription = discoveryService.heartbeatStream.listen((device) {
      if (isClosed) return;
      if (_localIdentity != null && device.peerId == _localIdentity!.peerId) {
        return;
      }
      _peerRegistry.touchLanHeartbeat(device);
    });

    _discoverySubscription = discoveryService.devicesStream.listen((devices) {
      if (isClosed) return;
      final nextIps = devices.map((d) => d.ip).toSet();
      for (final staleIp in _activeLanIps.difference(nextIps)) {
        _peerRegistry.detachLanIp(staleIp);
      }
      for (final d in devices) {
        if (_localIdentity != null && d.peerId == _localIdentity!.peerId) {
          continue;
        }
        _peerRegistry.upsertLanDiscovery(d);
      }
      _activeLanIps
        ..clear()
        ..addAll(nextIps);
    });
  }

  Future<void> initializeFabric({String? deviceName}) async {
    if (deviceName != null && deviceName.isNotEmpty && !isClosed) {
      emit(state.copyWith(deviceName: deviceName));
    }

    try {
      _localIdentity ??= await _identityService.loadOrCreate();
    } catch (_) {}

    if (isClosed) return;

    await _refreshTrustedDevices();

    LocalRadioCapabilities caps;
    try {
      caps = await _directBridge.getCapabilities();
    } catch (_) {
      caps = LocalRadioCapabilities.fallbackForPlatform(
        DirectNativeBridge.currentPlatform(),
      );
    }
    _localRadioCaps = caps;
    _localPeerCaps = PeerCapabilities(
      tlsSupported: true,
      direct5gHostCapable: caps.canHostDirect5g,
      directClientCapable: caps.hasWifi,
      multiStreamSupported: true,
      platform: caps.localPlatform,
    );

    if (!isClosed) {
      emit(
        state.copyWith(
          localPeerId: _localIdentity?.peerId,
          localFingerprint: _localIdentity?.certFingerprint,
          localRadioCapabilities: caps,
        ),
      );
    }

    if (_localIdentity != null) {
      discoveryService.updateAdvertisementMetadata(
        peerId: _localIdentity!.peerId,
        certFingerprint: _localIdentity!.certFingerprint,
        capabilities: _localPeerCaps,
        listenPort: AppConstants.transferPort,
      );

      if (caps.hasBle) {
        try {
          final beacon = BleBeaconPayload(
            caps: _localPeerCaps,
            peerId: _localIdentity!.peerId,
            fingerprintPrefix: _localIdentity!.certFingerprint.substring(0, 16),
            transferPort: AppConstants.transferPort,
          );
          await _directBridge.startBleDiscovery(
            beaconPayload: BleBeaconCodec.encode(beacon),
            peerId: _localIdentity!.peerId,
            peerName: deviceName ?? state.deviceName,
            fingerprint: _localIdentity!.certFingerprint,
          );
        } catch (_) {}
      }
    }

    _peerPruneTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (!isClosed) {
        _peerRegistry.pruneExpired();
      }
    });
  }

  Future<void> _refreshTrustedDevices() async {
    try {
      final trusted = await _trustedDevicesService.listTrustedDevices();
      _peerRegistry.setTrustedPeers({
        for (final d in trusted) d.peerId: d.certFingerprint,
      });
      if (!isClosed) {
        final peers = _peerRegistry.currentPeers;
        emit(
          state.copyWith(
            trustedDevices: trusted,
            unifiedPeers: peers,
            discoveredDevices: peers
                .map((p) => p.toDiscoveryModel())
                .toList(growable: false),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> setTransportPreference(TransportPreference preference) async {
    if (!isClosed) {
      emit(state.copyWith(transportPreference: preference));
    }
  }

  Future<void> revokeTrustedDevice(String peerId) async {
    try {
      await _trustedDevicesService.revokeDevice(peerId);
      await _refreshTrustedDevices();
    } catch (_) {}
  }

  Future<PairingToken?> trustPeerFromQr(String rawUri) async {
    final token = PairingQrCodec.decode(rawUri);
    if (token == null) return null;

    await _trustedDevicesService.trustDevice(
      peerId: token.peerId,
      certFingerprint: token.fingerprint,
      displayName: token.name,
      platform: token.platform.name,
    );
    _peerRegistry.upsertQrToken(token);
    await _refreshTrustedDevices();

    if (token.lanIp != null && token.lanIp!.isNotEmpty && !isClosed) {
      emit(state.copyWith(targetIp: token.lanIp));
    }
    return token;
  }

  Future<String?> buildLocalPairingUri({String? lanIpOverride}) async {
    _localIdentity ??= await _identityService.loadOrCreate();
    final identity = _localIdentity;
    if (identity == null) return null;

    String? bestIp = lanIpOverride;
    bestIp ??= await DiscoveryService.findBestLocalLanIp();

    return PairingQrCodec.encode(
      PairingToken(
        peerId: identity.peerId,
        fingerprint: identity.certFingerprint,
        name: state.deviceName,
        platform: DirectNativeBridge.currentPlatform(),
        lanIp: bestIp,
        port: AppConstants.transferPort,
      ),
    );
  }

  void _handleDirectFabricEvent(DirectFabricEvent event) {
    if (isClosed) return;
    if (event is DirectBleBeaconEvent) {
      final decoded = event.decodedPayload;
      if (decoded == null || decoded.peerId == _localIdentity?.peerId) {
        return;
      }
      _peerRegistry.upsertBleBeacon(
        decoded,
        bleAddress: event.bleAddress,
        deviceName: event.deviceName,
        rssi: event.rssi,
      );
      return;
    }

    if (event is DirectRadioStateEvent) {
      final caps = LocalRadioCapabilities(
        hasWifi: event.hasWifi,
        hasBle: event.hasBle,
        canHostDirect5g: event.canHostDirect5g,
        localPlatform: DirectNativeBridge.currentPlatform(),
      );
      _localRadioCaps = caps;
      _localPeerCaps = _localPeerCaps.copyWith(
        direct5gHostCapable: caps.canHostDirect5g,
        directClientCapable: caps.hasWifi,
      );
      emit(state.copyWith(localRadioCapabilities: caps));
      return;
    }

    if (event is DirectGattLinkRequestEvent) {
      if (event.action == 'hostReady') {
        final normalizedPeer = event.peerId.trim().toLowerCase();
        final normalizedFp = event.peerFingerprint?.trim().toLowerCase();
        final matchesReq = _pendingHostReadyRequestId != null &&
            event.requestId == _pendingHostReadyRequestId;
        final matchesPeer = _pendingHostReadyPeerId == null ||
            _pendingHostReadyPeerId == normalizedPeer;

        bool matchesFp = true;
        if (_pendingHostReadyExpectedFp != null &&
            _pendingHostReadyExpectedFp!.isNotEmpty) {
          if (normalizedFp != null && normalizedFp.isNotEmpty) {
            matchesFp = normalizedFp == _pendingHostReadyExpectedFp;
          } else {
            matchesFp = matchesPeer;
          }
        } else if (_pendingHostReadyExpectedFpPrefix != null &&
            _pendingHostReadyExpectedFpPrefix!.isNotEmpty) {
          if (normalizedFp != null && normalizedFp.isNotEmpty) {
            matchesFp = normalizedFp.startsWith(
              _pendingHostReadyExpectedFpPrefix!,
            );
          } else {
            matchesFp = matchesPeer;
          }
        } else if (!matchesPeer) {
          matchesFp = false;
        }

        final validMatch = _pendingHostReadyRequestId != null
            ? (matchesReq && matchesFp)
            : matchesPeer;
        if (_pendingHostReadyCompleter != null &&
            !_pendingHostReadyCompleter!.isCompleted &&
            validMatch) {
          _pendingHostReadyCompleter!.complete(event);
        }
        return;
      }

      if (event.action == 'joinHost') {
        unawaited(_handleIncomingJoinHost(event));
        return;
      }

      if (event.action == 'startHostAndWait') {
        unawaited(_handleIncomingStartHostRequest(event));
      }
    }
  }

  Future<void> _handleIncomingJoinHost(DirectGattLinkRequestEvent event) async {
    if (state.receiveFolder == null || event.ssid == null || event.psk == null) {
      return;
    }
    if (isClosed ||
        state.isTransferring ||
        state.isReceivingActive ||
        state.isDirectLinkConnecting ||
        _activeHostedDirectSession ||
        _isStartingHostedDirect) {
      return;
    }
    final normalizedPeerId = event.peerId.trim().toLowerCase();
    final trusted = normalizedPeerId.isNotEmpty
        ? await _trustedDevicesService.getDevice(normalizedPeerId)
        : null;
    if (trusted != null &&
        event.peerFingerprint != null &&
        event.peerFingerprint!.trim().isNotEmpty &&
        trusted.certFingerprint.trim().toLowerCase() !=
            event.peerFingerprint!.trim().toLowerCase()) {
      return;
    }
    final expectedSenderFp = event.peerFingerprint ?? trusted?.certFingerprint;

    try {
      _safeEmit(
        state.copyWith(
          isDirectLinkConnecting: true,
          directLinkStatus: 'Joining Direct 5GHz Link from ${event.peerName}...',
        ),
      );
      final conn = await _directBridge.connectDirectClient(
        ssid: event.ssid!,
        psk: event.psk!,
        frequencyMhz: event.frequencyMhz,
        expectedGatewayIp: event.hostIp,
      );
      if (conn == null || !event.useReverseConnect) {
        if (conn == null && event.useReverseConnect) {
          _safeEmit(
            state.copyWith(
              errorMessage:
                  'Could not join Direct 5GHz link from ${event.peerName}.',
            ),
          );
        }
        return;
      }

      final senderIp = conn.gatewayIp.isNotEmpty
          ? conn.gatewayIp
          : (event.hostIp ?? '192.168.49.1');
      final identity = _localIdentity ?? await _identityService.loadOrCreate();
      _localIdentity = identity;

      await _receiver.acceptReverseTransfer(
        senderIp: senderIp,
        port: event.port,
        saveDirectory: state.receiveFolder!,
        deviceName: state.deviceName,
        useTls: true,
        expectedSenderFingerprint: expectedSenderFp,
        reverseAuthToken: event.reverseToken,
        localIdentity: identity,
        onUpdate: _handleReceiverModelUpdate,
        onRequestAuth: (ip, name, count, size) => _authorizeIncomingTransfer(
          TransferAuthRequest(
            senderIp: ip,
            senderDeviceName: name,
            fileCount: count,
            totalSizeMB: size,
          ),
        ),
        onRequestAuthV2: _authorizeIncomingTransfer,
        onAuthDismissed: _handleAuthDismissed,
        onDone: _handleReceiverTransferDone,
      );
    } catch (_) {
    } finally {
      await _directBridge.stopDirectSession();
      _safeEmit(
        state.copyWith(
          isDirectLinkConnecting: false,
          clearDirectLinkStatus: true,
        ),
      );
    }
  }

  void _scheduleHostedDirectWatchdog() {
    _hostedDirectWatchdogTimer?.cancel();
    _hostedDirectWatchdogTimer = Timer(const Duration(seconds: 90), () {
      if (isClosed) return;
      if (_activeHostedDirectSession &&
          !state.isReceivingActive &&
          !state.isTransferring) {
        unawaited(_stopHostedDirectSession());
      }
    });
  }

  Future<void> _stopHostedDirectSession() async {
    _hostedDirectWatchdogTimer?.cancel();
    _hostedDirectWatchdogTimer = null;
    if (!_activeHostedDirectSession) return;
    _activeHostedDirectSession = false;
    await _directBridge.stopDirectSession();
  }

  Future<void> _handleIncomingStartHostRequest(
    DirectGattLinkRequestEvent event,
  ) async {
    if (state.receiveFolder == null) return;
    if (isClosed ||
        state.isTransferring ||
        state.isReceivingActive ||
        state.isDirectLinkConnecting ||
        _isStartingHostedDirect) {
      return;
    }
    final normalizedPeerId = event.peerId.trim().toLowerCase();
    final trusted = normalizedPeerId.isNotEmpty
        ? await _trustedDevicesService.getDevice(normalizedPeerId)
        : null;
    if (trusted != null &&
        event.peerFingerprint != null &&
        event.peerFingerprint!.trim().isNotEmpty &&
        trusted.certFingerprint.trim().toLowerCase() !=
            event.peerFingerprint!.trim().toLowerCase()) {
      return;
    }

    _isStartingHostedDirect = true;
    _hostedDirectWatchdogTimer?.cancel();
    try {
      if (!state.isReceiving) {
        await startReceiver();
      }
      final hostInfo = await _directBridge.startDirectHost(prefer5Ghz: true);
      if (hostInfo == null) return;
      _activeHostedDirectSession = true;

      final peer = _peerRegistry.getByPeerId(event.peerId);
      final bleAddr = (peer?.bleAddress != null && peer!.bleAddress!.isNotEmpty)
          ? peer.bleAddress
          : event.sourceBleAddress;
      if (bleAddr == null || bleAddr.isEmpty) {
        await _stopHostedDirectSession();
        return;
      }

      final identity = _localIdentity ?? await _identityService.loadOrCreate();
      _localIdentity = identity;

      final resp = await _directBridge.exchangeGattLink(
        bleAddress: bleAddr,
        payload: <String, dynamic>{
          'requestId': event.requestId,
          'peerId': identity.peerId,
          'peerName': state.deviceName,
          'peerFingerprint': identity.certFingerprint,
          'action': 'hostReady',
          'ssid': hostInfo.ssid,
          'psk': hostInfo.psk,
          'hostIp': hostInfo.hostIp,
          'port': AppConstants.transferPort,
          'reverseConnect': false,
          'frequencyMhz': hostInfo.frequencyMhz,
        },
      );
      if (resp == null || resp['ok'] == false) {
        await _stopHostedDirectSession();
        return;
      }
      _scheduleHostedDirectWatchdog();
    } catch (_) {
      await _stopHostedDirectSession();
    } finally {
      _isStartingHostedDirect = false;
    }
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

      // If receiver was active (but not mid-transfer or negotiating direct link),
      // restart it to bind to new IP.
      if (state.isReceiving &&
          !state.isReceivingActive &&
          !state.isDirectLinkConnecting &&
          !state.isTransferring &&
          !_isStartingReceiver) {
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

    if (isClosed) return;
    try {
      await initializeFabric(deviceName: deviceName);
    } catch (_) {}

    if (isClosed) return;
    await discoveryService.startDiscovery(
      deviceName,
      peerId: _localIdentity?.peerId,
      certFingerprint: _localIdentity?.certFingerprint,
      capabilities: _localPeerCaps,
      listenPort: AppConstants.transferPort,
    );
  }

  Future<void> _startReceiverAutomatically() async {
    // Wait a bit for permissions to be handled in main.dart or _prepareRequirements
    await Future.delayed(const Duration(milliseconds: 1500));

    if (state.isReceiving) return;

    String? defaultPath;

    // 1. Try to load saved custom path first
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final file = File(p.join(docDir.path, 'daphq_receive_path.txt'));
      if (file.existsSync()) {
        final savedPath = await file.readAsString();
        if (savedPath.isNotEmpty && Directory(savedPath).existsSync()) {
          defaultPath = savedPath;
        }
      }
    } catch (_) {}

    // 2. If no valid saved path, fallback to OS defaults
    if (defaultPath == null) {
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
    }

    if (defaultPath != null) {
      setReceiveFolder(defaultPath, saveToPrefs: false);
      startReceiver();
    }

    if (!isClosed) {
      emit(state.copyWith(isLocatingFolder: false));
    }
  }

  void toggleAdvancedMode() {
    _safeEmit(state.copyWith(isAdvancedMode: !state.isAdvancedMode));
  }

  Future<void> addExternalFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    _safeEmit(state.copyWith(isAddingFiles: true));

    try {
      final List<String> cleanedPaths = [];
      for (var path in paths) {
        // Clean path: remove quotes that might be added by Windows shell escaping (e.g. "C:\" -> C:")
        var p = path.trim();
        if (p.startsWith('"')) p = p.substring(1);
        if (p.endsWith('"')) p = p.substring(0, p.length - 1);
        cleanedPaths.add(p);
      }

      // Check if the path exists as either a file or a directory asynchronously
      final List<String> validPaths = [];
      final Map<String, bool> newDirs = {};

      // Process in chunks to keep UI responsive
      const int chunkSize = 50;
      for (int i = 0; i < cleanedPaths.length; i += chunkSize) {
        final chunk = cleanedPaths.skip(i).take(chunkSize);
        await Future.wait(
          chunk.map((p) async {
            final type = await FileSystemEntity.type(p);
            if (type != FileSystemEntityType.notFound) {
              validPaths.add(p);
              newDirs[p] = type == FileSystemEntityType.directory;
            }
          }),
        );
        // Yield to event loop
        await Future.delayed(Duration.zero);
      }

      if (validPaths.isNotEmpty) {
        final updatedDirs = Map<String, bool>.from(state.selectedPathsIsDir)
          ..addAll(newDirs);
        _safeEmit(
          state.copyWith(
            selectedPaths: {...state.selectedPaths, ...validPaths}.toList(),
            selectedPathsIsDir: updatedDirs,
          ),
        );
      }
    } catch (e) {
      _safeEmit(state.copyWith(errorMessage: "Error adding external files: $e"));
    } finally {
      _safeEmit(state.copyWith(isAddingFiles: false));
    }
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
        _safeEmit(state.copyWith(showStorageSettingsDialog: true));
        return false;
      } else {
        _safeEmit(
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
      if (_notifCompleter != null && !_notifCompleter!.isCompleted) {
        _notifCompleter!.complete(false);
      }
      final completer = Completer<bool>();
      _notifCompleter = completer;
      _safeEmit(state.copyWith(showNotificationWarningDialog: true));
      bool proceed = await completer.future;
      if (identical(_notifCompleter, completer)) {
        _notifCompleter = null;
      }
      if (!proceed) return false;
      showedWarning = true;
      _safeEmit(
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

  void setReceiveFolder(String path, {bool saveToPrefs = true}) {
    _safeEmit(state.copyWith(receiveFolder: path));

    // Save to local text file asynchronously
    if (saveToPrefs) {
      getApplicationDocumentsDirectory()
          .then((docDir) async {
            final file = File(p.join(docDir.path, 'daphq_receive_path.txt'));
            await file.writeAsString(path);
          })
          .catchError((_) {});
    }

    // If receiver is already running, restart it with the new folder
    // but only if there is no active transfer happening right now.
    if (state.isReceiving && !state.isReceivingActive) {
      startReceiver();
    }
  }

  void setTargetIp(String ip) {
    _safeEmit(state.copyWith(targetIp: ip));
  }

  /// Surfaces a share-intent copy failure reported by the native layer
  /// (plan T-015) — previously a failed copy was dropped silently and the
  /// transfer proceeded without that file.
  void reportShareCopyError(String fileName) {
    if (isClosed) return;
    emit(state.copyWith(
      errorMessage: 'Could not copy "$fileName" from the share. '
          'Please try sharing it again.',
    ));
  }

  void clearFeedback() {
    _safeEmit(state.copyWith(clearFeedback: true));
  }

  void stopReceiver({String? reason}) {
    _receiverSessionSeq++;
    _receiver.stop(reason: reason);
    unawaited(_stopHostedDirectSession());
    discoveryService.triggerBroadcast(
      isOnline: false,
    ); // Signal other devices to remove us instantly
    _safeEmit(
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

  void _handleAuthDismissed() {
    _pendingAuthV2Request = null;
    if (!isClosed && state.authRequest != null) {
      emit(state.copyWith(clearAuthRequest: true));
    }
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(false);
    }
  }

  void _handleReceiverModelUpdate(TransferModel model) {
    // Capture phase synchronously before async queue executes
    final TransferPhase phase = model.phase != TransferPhase.idle
        ? model.phase
        : _receiver.currentPhase;
    _receiverUpdateChain = _receiverUpdateChain.then((_) async {
      if (isClosed) return;
      final bool isBusy =
          phase == TransferPhase.receiving ||
          phase == TransferPhase.finalizing;

      final bool wasActive = state.isReceivingActive;

      // Write log when transitioning from busy to idle (serialized cleanly)
      if (wasActive && !isBusy) {
        unawaited(_stopHostedDirectSession());
        final String status = phase == TransferPhase.done
            ? "success"
            : (phase == TransferPhase.cancelled ? "cancelled" : "failed");

        final List<dynamic> filesList =
            _receiver.lastReceivedMetadata?["files"] ?? [];
        if (filesList.isNotEmpty) {
          final Map<String, double> items = {};
          for (final f in filesList) {
            final String pathStr = f["path"] as String;
            final int size = f["size"] as int;
            final String topLevelName = p.posix.split(pathStr).first;
            items[topLevelName] =
                (items[topLevelName] ?? 0.0) + (size / 1024 / 1024);
          }

          final List<HistoryEntryInput> entries = [];
          for (final entry in items.entries) {
            entries.add(
              HistoryEntryInput(
                fileName: entry.key,
                fileSizeMB: entry.value,
                direction: 'receive',
                status: status,
                localPath: status == 'success'
                    ? p.join(state.receiveFolder!, entry.key)
                    : null,
              ),
            );
          }
          await HistoryService.addEntries(entries);
        } else {
          if (model.fileName.isNotEmpty && model.totalSize > 0) {
            await HistoryService.addEntry(
              fileName: model.fileName,
              fileSizeMB: model.totalSize,
              direction: 'receive',
              status: status,
              localPath: status == 'success' ? state.receiveFolder : null,
            );
          }
        }
      }

      if (!isClosed) {
        emit(
          state.copyWith(
            model: model,
            isReceivingActive: isBusy,
            isLastTransferIncoming: isBusy ? true : state.isLastTransferIncoming,
            showProgressView: isBusy ? true : state.showProgressView,
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
    }).catchError((_) {});
  }

  Future<bool> _authorizeIncomingTransfer(TransferAuthRequest req) async {
    bool isMismatch = false;

    if (req.senderPeerId != null && req.senderFingerprint != null) {
      final trust = await _trustedDevicesService.checkTrust(
        req.senderPeerId!,
        req.senderFingerprint!,
      );
      if (trust == TrustCheckResult.trusted &&
          req.isTls &&
          req.isIdentityVerified) {
        await _trustedDevicesService.touchLastSeen(
          req.senderPeerId!,
          displayName: req.senderDeviceName,
        );
        await _refreshTrustedDevices();
        return true;
      } else if (trust == TrustCheckResult.fingerprintMismatch) {
        isMismatch = true;
      }
    }

    final sasCode = req.sasCode ??
        ((req.senderFingerprint != null && _localIdentity != null)
            ? _localIdentity!.computeSasWith(req.senderFingerprint!)
            : null);

    try {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        windowManager.isMinimized().then((isMinimized) async {
          if (isMinimized) await windowManager.restore();
          await windowManager.setAlwaysOnTop(true);
          await windowManager.show();
          await windowManager.focus();
          await Future.delayed(const Duration(milliseconds: 100));
          await windowManager.setAlwaysOnTop(false);
        }).catchError((_) {});
      } else if (Platform.isAndroid) {
        FlutterForegroundTask.wakeUpScreen();
        FlutterForegroundTask.launchApp();
      }
    } catch (_) {}

    if (isClosed) return false;

    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(false);
    }

    _pendingAuthV2Request = req;
    final completer = Completer<bool>();
    _authCompleter = completer;
    _safeEmit(
      state.copyWith(
        authRequest: AuthRequest(
          senderIp: req.senderIp,
          senderName: req.senderDeviceName,
          fileCount: req.fileCount,
          totalSizeMB: req.totalSizeMB,
          senderPeerId: req.senderPeerId,
          senderFingerprint: req.senderFingerprint,
          sasCode: sasCode,
          isTls: req.isTls,
          isTrustedPeer: false,
          isFingerprintMismatch: isMismatch,
        ),
      ),
    );
    return completer.future;
  }

  void _handleReceiverTransferDone() {
    unawaited(_stopHostedDirectSession());
    final bool failed = _receiver.currentPhase == TransferPhase.failed;
    if (state.isReceiving && !failed) {
      if (Platform.isAndroid) {
        FlutterForegroundTask.updateService(
          notificationTitle: AppConstants.appName,
          notificationText: 'Receiver idle...',
          notificationButtons: [
            const NotificationButton(
              id: 'stopReceivingButton',
              text: 'Stop Receiving',
            ),
          ],
        );
      }
    } else if (failed) {
      _stopForegroundService();
    }

    // Ensure UI reflects that receiver is no longer active
    _safeEmit(
      state.copyWith(
        isReceiving: failed ? false : state.isReceiving,
        isReceivingActive: false,
      ),
    );
  }

  Future<void> startReceiver() async {
    if (state.receiveFolder == null || _isStartingReceiver) return;
    _isStartingReceiver = true;
    final int myRxToken = ++_receiverSessionSeq;

    try {
      if (!await _prepareRequirements() ||
          isClosed ||
          myRxToken != _receiverSessionSeq) {
        return;
      }

      DeviceIdentity? identity = _localIdentity;
      if (identity == null) {
        try {
          identity = await _identityService.loadOrCreate();
          _localIdentity = identity;
        } catch (_) {}
      }
      if (isClosed || myRxToken != _receiverSessionSeq) return;

      _safeEmit(state.copyWith(isReceiving: true, isTransferring: false));
      discoveryService.triggerBroadcast(); // Signal other devices immediately
      await _startForegroundService(
        AppConstants.appName,
        "Waiting for incoming files...",
        button: const NotificationButton(
          id: 'stopReceivingButton',
          text: 'Stop Receiving',
        ),
      );
      if (isClosed || myRxToken != _receiverSessionSeq) return;

      unawaited(
        _receiver
            .startReceiver(
              saveDirectory: state.receiveFolder!,
              deviceName: state.deviceName,
              tlsContext: identity?.createServerContext(),
              localIdentity: identity,
              onAuthDismissed: _handleAuthDismissed,
              onUpdate: _handleReceiverModelUpdate,
              onRequestAuth: (senderIp, senderName, count, size) =>
                  _authorizeIncomingTransfer(
                    TransferAuthRequest(
                      senderIp: senderIp,
                      senderDeviceName: senderName,
                      fileCount: count,
                      totalSizeMB: size,
                    ),
                  ),
              onRequestAuthV2: _authorizeIncomingTransfer,
              onDone: () {
                if (myRxToken != _receiverSessionSeq || isClosed) return;
                _handleReceiverTransferDone();
              },
            )
            .catchError((_) {
              if (myRxToken != _receiverSessionSeq || isClosed) return;
              _stopForegroundService();
              _safeEmit(
                state.copyWith(isReceiving: false, isReceivingActive: false),
              );
            }),
      );
    } finally {
      _isStartingReceiver = false;
    }
  }

  Future<void> resolveAuth(bool accept, {bool trustPeer = false}) async {
    final ar = state.authRequest;
    final pendingReq = _pendingAuthV2Request ??
        (ar == null
            ? null
            : TransferAuthRequest(
                senderIp: ar.senderIp,
                senderDeviceName: ar.senderName,
                fileCount: ar.fileCount,
                totalSizeMB: ar.totalSizeMB,
                senderPeerId: ar.senderPeerId,
                senderFingerprint: ar.senderFingerprint,
                sasCode: ar.sasCode,
                isTls: ar.isTls,
              ));
    _pendingAuthV2Request = null;

    if (accept &&
        trustPeer &&
        pendingReq?.senderPeerId != null &&
        pendingReq?.senderFingerprint != null) {
      await _trustedDevicesService.trustDevice(
        peerId: pendingReq!.senderPeerId!,
        certFingerprint: pendingReq.senderFingerprint!,
        displayName: pendingReq.senderDeviceName,
        platform: _peerRegistry
                .getByPeerId(pendingReq.senderPeerId!)
                ?.platform
                .name ??
            'unknown',
      );
      await _refreshTrustedDevices();
    }

    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(accept);
    }
    if (!isClosed) {
      emit(state.copyWith(clearAuthRequest: true));
    }
  }

  void resolveNotificationWarning(bool proceed) {
    if (_notifCompleter != null && !_notifCompleter!.isCompleted) {
      _notifCompleter!.complete(proceed);
    }
    _safeEmit(state.copyWith(clearFeedback: true));
  }

  Future<void> addSelectedPaths(
    List<String> paths, {
    bool showLoading = true,
  }) async {
    if (paths.isEmpty) return;

    if (showLoading) {
      _safeEmit(state.copyWith(isAddingFiles: true));
    }

    final currentRevision = _sessionRevision;

    try {
      // 1. Process files asynchronously WITHOUT reading the current state
      final Map<String, bool> newDirs = {};

      // Give UI a chance to render the loading spinner if needed
      if (showLoading) {
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // Process in chunks to prevent freezing the event loop
      const int chunkSize = 50;
      for (int i = 0; i < paths.length; i += chunkSize) {
        if (_sessionRevision != currentRevision) return; // Abort if cleared

        final chunk = paths.skip(i).take(chunkSize);
        await Future.wait(
          chunk.map((p) async {
            newDirs[p] = await FileSystemEntity.isDirectory(p);
          }),
        );
        // Yield to event loop
        await Future.delayed(Duration.zero);
      }

      if (_sessionRevision != currentRevision) {
        return; // Final check before emitting
      }

      // 2. Synchronously read the LATEST state and update it
      // This prevents race conditions if addSelectedPaths is called concurrently
      final newPathsSet = {...state.selectedPaths, ...paths};
      final newList = newPathsSet.toList();
      final updatedDirs = Map<String, bool>.from(state.selectedPathsIsDir)
        ..addAll(newDirs);

      _safeEmit(
        state.copyWith(selectedPaths: newList, selectedPathsIsDir: updatedDirs),
      );
    } catch (_) {
    } finally {
      if (showLoading && _sessionRevision == currentRevision) {
        _safeEmit(state.copyWith(isAddingFiles: false));
      }
    }
  }

  void removeSelectedPath(String path) {
    final newList = List<String>.from(state.selectedPaths)..remove(path);
    _safeEmit(state.copyWith(selectedPaths: newList));
  }

  int _sessionRevision = 0;

  void clearSelection() {
    _sessionRevision++;
    if (Platform.isAndroid) {
      NativeShareService.cancel();
    }
    _safeEmit(state.copyWith(clearSelection: true));
  }

  Future<void> pickItems(FileType type) async {
    _safeEmit(state.copyWith(isAddingFiles: true));
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
        await addSelectedPaths(result.paths.whereType<String>().toList());
      }
    } catch (e) {
      _safeEmit(state.copyWith(errorMessage: "Error picking files: $e"));
    } finally {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        try {
          await windowManager.focus();
        } catch (_) {}
      }
      _safeEmit(state.copyWith(isAddingFiles: false));
    }
  }

  Future<void> pickFolder() async {
    _safeEmit(state.copyWith(isAddingFiles: true));
    try {
      final path = await FilePicker.getDirectoryPath();
      if (path != null) {
        await addSelectedPaths([path]);
      }
    } catch (e) {
      _safeEmit(state.copyWith(errorMessage: "Error picking folder: $e"));
    } finally {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        try {
          await windowManager.focus();
        } catch (_) {}
      }
      _safeEmit(state.copyWith(isAddingFiles: false));
    }
  }

  Future<void> sendData({List<String>? paths}) async {
    final itemsToSend = paths ?? state.selectedPaths;
    final trimmedTarget = state.targetIp.trim();
    if (itemsToSend.isEmpty ||
        state.isTransferring ||
        _isPreparingSend ||
        trimmedTarget.isEmpty) {
      return;
    }

    final matchedPeer = _findUnifiedPeerForTarget(trimmedTarget);
    if (matchedPeer != null) {
      await _executeSend(
        itemsToSend: itemsToSend,
        targetIp: trimmedTarget,
        peer: matchedPeer,
      );
      return;
    }

    String targetDeviceName = "the other device";
    try {
      targetDeviceName = state.discoveredDevices
          .firstWhere((d) => d.ip == trimmedTarget)
          .name;
    } catch (_) {}

    final syntheticPeer = UnifiedPeer(
      peerId: 'legacy:$trimmedTarget',
      name: targetDeviceName,
      platform: PeerPlatform.unknown,
      lanIp: trimmedTarget,
      lastSeenLan: DateTime.now(),
    );
    await _executeSend(
      itemsToSend: itemsToSend,
      targetIp: trimmedTarget,
      peer: syntheticPeer,
    );
  }

  Future<void> sendToPeer(UnifiedPeer peer, {List<String>? paths}) async {
    final itemsToSend = paths ?? state.selectedPaths;
    if (itemsToSend.isEmpty || state.isTransferring || _isPreparingSend) {
      return;
    }
    final displayTarget =
        peer.lanIp ?? 'ble:${peer.bleAddress ?? peer.peerId}';
    _safeEmit(state.copyWith(targetIp: displayTarget));
    await _executeSend(
      itemsToSend: itemsToSend,
      targetIp: displayTarget,
      peer: peer,
    );
  }

  UnifiedPeer? _findUnifiedPeerForTarget(String target) {
    for (final peer in state.unifiedPeers) {
      if (peer.lanIp == target ||
          peer.bleAddress == target ||
          'ble:${peer.bleAddress ?? peer.peerId}' == target) {
        return peer;
      }
    }
    return null;
  }

  Future<bool> _probeLanHealthy(String ip, int port) async {
    try {
      final sock = await Socket.connect(
        ip,
        port,
        timeout: const Duration(milliseconds: 900),
      );
      await sock.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _executeSend({
    required List<String> itemsToSend,
    required String targetIp,
    required UnifiedPeer peer,
  }) async {
    if (_isPreparingSend || state.isTransferring) return;
    final int mySendToken = ++_sendSessionToken;
    _isPreparingSend = true;
    try {
      if (!await _prepareRequirements() ||
          isClosed ||
          mySendToken != _sendSessionToken) {
        return;
      }
    } finally {
      _isPreparingSend = false;
    }

    void onTokenizedSenderUpdate(TransferModel model) {
      if (mySendToken != _sendSessionToken || isClosed) return;
      _handleSenderModelUpdate(model);
    }

    _safeEmit(
      state.copyWith(
        isTransferring: true,
        isLastTransferIncoming: false,
        showProgressView: true,
      ),
    );

    await _startForegroundService(
      AppConstants.appName,
      "Sending files...",
      button: const NotificationButton(
        id: 'cancelSendingButton',
        text: 'Cancel Sending',
      ),
    );
    if (mySendToken != _sendSessionToken || isClosed) return;

    // Clear selection immediately so it doesn't pop back on error
    _safeEmit(state.copyWith(clearSelection: true));

    bool directSessionStarted = false;
    try {
      final identity = _localIdentity ?? await _identityService.loadOrCreate();
      _localIdentity = identity;
      final localCaps =
          _localRadioCaps ??
          LocalRadioCapabilities.fallbackForPlatform(
            DirectNativeBridge.currentPlatform(),
          );

      bool lanProbeHealthy = true;
      if (peer.hasLan &&
          peer.hasBle &&
          localCaps.hasBle &&
          state.transportPreference == TransportPreference.autoSmart) {
        lanProbeHealthy = await _probeLanHealthy(peer.lanIp!, peer.port);
      }

      if (mySendToken != _sendSessionToken || isClosed) return;

      final plan = _linkEvaluator.planTransfer(
        peer: peer,
        preference: state.transportPreference,
        localCaps: localCaps,
        localPeerId: identity.peerId,
        lanProbeHealthy: lanProbeHealthy,
      );

      if (plan.strategy == LinkExecutionStrategy.manualQrFallback) {
        throw "Peer is unreachable over LAN or Direct BLE (${plan.reason}). Use QR Pairing to exchange endpoints.";
      }

      if (plan.strategy == LinkExecutionStrategy.bleTriggeredDirectP2p) {
        directSessionStarted = true;
        await _executeDirectP2pTransfer(
          peer: peer,
          itemsToSend: itemsToSend,
          plan: plan,
          identity: identity,
          onUpdate: onTokenizedSenderUpdate,
        );
      } else {
        final effectiveIp = peer.lanIp ?? targetIp;
        await _sender.sendData(
          paths: itemsToSend,
          targetIp: effectiveIp,
          targetDeviceName: peer.name,
          senderDeviceName: state.deviceName,
          port: peer.port,
          useTls: plan.useTls,
          expectedPeerFingerprint: peer.certFingerprint,
          localIdentity: identity,
          parallelStreams: plan.parallelStreams,
          onVerifyPeerFingerprint: peer.fingerprintPrefix != null
              ? (actualFp) async => actualFp.toLowerCase().startsWith(
                    peer.fingerprintPrefix!.toLowerCase(),
                  )
              : null,
          onUpdate: onTokenizedSenderUpdate,
        );
      }

      // Log success individually for each item atomically
      if (itemsToSend.isNotEmpty) {
        try {
          final List<HistoryEntryInput> entries = [];
          for (final path in itemsToSend) {
            final double sizeMB = await _getPathSizeMB(path);
            entries.add(
              HistoryEntryInput(
                fileName: p.basename(path),
                fileSizeMB: sizeMB,
                direction: 'send',
                status: 'success',
              ),
            );
          }
          await HistoryService.addEntries(entries);
        } catch (_) {}
      }

      if (mySendToken == _sendSessionToken && !isClosed) {
        _safeEmit(state.copyWith(isTransferring: false, clearFeedback: true));
      }

      if (mySendToken == _sendSessionToken) {
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
    } catch (e) {
      final TransferPhase terminalPhase = e is TransferSendException
          ? e.phase
          : (state.model.phase == TransferPhase.cancelled
                ? TransferPhase.cancelled
                : TransferPhase.failed);
      final String status =
          terminalPhase == TransferPhase.cancelled ? "cancelled" : "failed";

      // Log failure/cancellation even if cancelSending bumped _sendSessionToken,
      // while shielding UI state & foreground service updates via token check below.
      if (itemsToSend.isNotEmpty) {
        try {
          final List<HistoryEntryInput> entries = [];
          for (final path in itemsToSend) {
            final double sizeMB = await _getPathSizeMB(path);
            entries.add(
              HistoryEntryInput(
                fileName: p.basename(path),
                fileSizeMB: sizeMB,
                direction: 'send',
                status: status,
              ),
            );
          }
          await HistoryService.addEntries(entries);
        } catch (_) {}
      }

      if (mySendToken != _sendSessionToken) {
        return;
      }

      String errorMsg = e.toString();
      if (errorMsg.endsWith('.')) {
        errorMsg = errorMsg.substring(0, errorMsg.length - 1);
      }

      if (mySendToken == _sendSessionToken && !isClosed) {
        final TransferModel nextModel = state.model.phase == terminalPhase
            ? state.model
            : TransferModel(
                status: "$errorMsg. Ready & Waiting...",
                transferred: state.model.transferred,
                totalSize: state.model.totalSize,
                progress: state.model.progress,
                fileName: state.model.fileName,
                phase: terminalPhase,
              );
        _safeEmit(
          state.copyWith(
            isTransferring: false,
            errorMessage: terminalPhase == TransferPhase.failed &&
                    !state.showProgressView
                ? errorMsg
                : null,
            model: nextModel,
          ),
        );
      }
    } finally {
      if (directSessionStarted && mySendToken == _sendSessionToken) {
        await _directBridge.stopDirectSession();
      }
      if (mySendToken == _sendSessionToken) {
        _safeEmit(
          state.copyWith(
            isDirectLinkConnecting: false,
            clearDirectLinkStatus: true,
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
  }

  void _handleSenderModelUpdate(TransferModel model) {
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
  }

  Future<void> _executeDirectP2pTransfer({
    required UnifiedPeer peer,
    required List<String> itemsToSend,
    required LinkPlan plan,
    required DeviceIdentity identity,
    required void Function(TransferModel) onUpdate,
  }) async {
    final bleAddr = peer.bleAddress;
    if (bleAddr == null || bleAddr.isEmpty) {
      throw "Direct BLE link unavailable for ${peer.name}.";
    }

    final reqId = generateTransferSessionId();
    String? verifiedFingerprint = peer.certFingerprint;

    if (plan.shouldLocalHostDirectGroup) {
      if (!isClosed) {
        emit(
          state.copyWith(
            isDirectLinkConnecting: true,
            directLinkStatus: 'Creating 5GHz Direct Link for ${peer.name}...',
          ),
        );
      }
      final hostInfo = await _directBridge.startDirectHost(prefer5Ghz: true);
      if (hostInfo == null) {
        if (peer.hasLan) {
          await _sender.sendData(
            paths: itemsToSend,
            targetIp: peer.lanIp!,
            targetDeviceName: peer.name,
            senderDeviceName: state.deviceName,
            port: peer.port,
            useTls: plan.useTls,
            expectedPeerFingerprint: peer.certFingerprint,
            localIdentity: identity,
            parallelStreams: plan.parallelStreams,
            onVerifyPeerFingerprint:
                peer.certFingerprint == null && peer.fingerprintPrefix != null
                ? (actualFp) async => actualFp.toLowerCase().startsWith(
                    peer.fingerprintPrefix!.toLowerCase(),
                  )
                : null,
            onUpdate: onUpdate,
          );
          return;
        }
        throw "Could not start Direct 5GHz Wi-Fi P2P host on this device.";
      }

      if (!isClosed) {
        emit(
          state.copyWith(
            directLinkStatus: 'Signaling ${peer.name} over BLE GATT...',
          ),
        );
      }

      final String reverseToken = generateTransferSessionId();
      final Completer<void> joinHostDone = Completer<void>();

      Future<void> dispatchJoinHost(int boundPort) async {
        try {
          final gattResp = await _directBridge.exchangeGattLink(
            bleAddress: bleAddr,
            payload: <String, dynamic>{
              'requestId': reqId,
              'peerId': identity.peerId,
              'peerName': state.deviceName,
              'peerFingerprint': identity.certFingerprint,
              'action': 'joinHost',
              'ssid': hostInfo.ssid,
              'psk': hostInfo.psk,
              'hostIp': hostInfo.hostIp,
              'port': boundPort,
              'reverseConnect': true,
              'reverseToken': reverseToken,
              'frequencyMhz': hostInfo.frequencyMhz,
            },
          );
          if (gattResp == null || gattResp['ok'] == false) {
            _sender.cancel(
              reason: "Could not reach ${peer.name} over BLE GATT.",
            );
            return;
          }
          final fp = gattResp['fp'] as String?;
          if (fp != null && fp.length == 64) {
            final normalizedFp = fp.toLowerCase();
            final trusted = await _trustedDevicesService.getDevice(peer.peerId);
            if (trusted != null &&
                trusted.certFingerprint.trim().toLowerCase() != normalizedFp) {
              _sender.cancel(
                reason: "Peer certificate mismatch for ${peer.name}.",
              );
              return;
            }
            verifiedFingerprint = normalizedFp;
          }
        } catch (_) {
          _sender.cancel(
            reason: "Could not reach ${peer.name} over BLE GATT.",
          );
        } finally {
          if (!joinHostDone.isCompleted) {
            joinHostDone.complete();
          }
        }
      }

      await _sender.sendData(
        paths: itemsToSend,
        targetIp: hostInfo.hostIp,
        targetDeviceName: peer.name,
        senderDeviceName: state.deviceName,
        port: 0,
        useTls: plan.useTls,
        expectedPeerFingerprint: verifiedFingerprint,
        expectedPeerFingerprintProvider: () => verifiedFingerprint,
        localIdentity: identity,
        parallelStreams: plan.parallelStreams,
        listenForReverseReceiver: true,
        reverseAuthToken: reverseToken,
        onReverseListening: (boundPort) {
          unawaited(dispatchJoinHost(boundPort));
        },
        onVerifyPeerFingerprint: (actualFp) async {
          if (verifiedFingerprint == null && !joinHostDone.isCompleted) {
            await joinHostDone.future.timeout(
              const Duration(seconds: 5),
              onTimeout: () {},
            );
          }
          if (verifiedFingerprint != null) {
            return actualFp.toLowerCase() == verifiedFingerprint!.toLowerCase();
          }
          if (peer.fingerprintPrefix != null) {
            return actualFp.toLowerCase().startsWith(
              peer.fingerprintPrefix!.toLowerCase(),
            );
          }
          return false;
        },
        onUpdate: onUpdate,
      );
      return;
    }

    // Receiver hosts the 5GHz GO (e.g. Windows sending to Android).
    if (!isClosed) {
      emit(
        state.copyWith(
          isDirectLinkConnecting: true,
          directLinkStatus: 'Requesting ${peer.name} 5GHz Direct Link via BLE...',
        ),
      );
    }

    _pendingHostReadyPeerId = peer.peerId.trim().toLowerCase();
    _pendingHostReadyRequestId = reqId;
    _pendingHostReadyExpectedFp = peer.certFingerprint?.trim().toLowerCase();
    _pendingHostReadyExpectedFpPrefix = peer.fingerprintPrefix?.trim().toLowerCase();
    final hostReadyCompleter = Completer<DirectGattLinkRequestEvent>();
    hostReadyCompleter.future.catchError((_) => DirectGattLinkRequestEvent(
      requestId: reqId,
      peerId: peer.peerId,
      peerName: peer.name,
      action: 'hostReady',
    ));
    _pendingHostReadyCompleter = hostReadyCompleter;

    late final DirectGattLinkRequestEvent hostReady;
    try {
      final gattResp = await _directBridge.exchangeGattLink(
        bleAddress: bleAddr,
        payload: <String, dynamic>{
          'requestId': reqId,
          'peerId': identity.peerId,
          'peerName': state.deviceName,
          'peerFingerprint': identity.certFingerprint,
          'action': 'startHostAndWait',
          'port': peer.port,
          'reverseConnect': plan.useReverseConnect,
        },
      );
      if (gattResp == null || gattResp['ok'] == false) {
        throw "Could not reach ${peer.name} over BLE GATT.";
      }
      final fp = (gattResp['fp'] as String?)?.trim().toLowerCase();
      if (fp != null && fp.length == 64) {
        final pinned = _pendingHostReadyExpectedFp;
        final prefix = _pendingHostReadyExpectedFpPrefix;
        if ((pinned != null && pinned.isNotEmpty && pinned != fp) ||
            (pinned == null &&
                prefix != null &&
                prefix.isNotEmpty &&
                !fp.startsWith(prefix))) {
          throw "Peer certificate mismatch for ${peer.name}.";
        }
        verifiedFingerprint = fp;
        _pendingHostReadyExpectedFp = fp;
      }

      hostReady = await hostReadyCompleter.future.timeout(
        const Duration(seconds: 15),
      );
    } finally {
      if (identical(_pendingHostReadyCompleter, hostReadyCompleter)) {
        _pendingHostReadyCompleter = null;
        _pendingHostReadyPeerId = null;
        _pendingHostReadyRequestId = null;
        _pendingHostReadyExpectedFp = null;
        _pendingHostReadyExpectedFpPrefix = null;
      }
    }

    if (hostReady.peerFingerprint != null &&
        hostReady.peerFingerprint!.length == 64) {
      verifiedFingerprint = hostReady.peerFingerprint!.toLowerCase();
    }

    if (hostReady.ssid == null || hostReady.psk == null) {
      throw "Direct Wi-Fi credentials were not returned by ${peer.name}.";
    }

    if (!isClosed) {
      emit(
        state.copyWith(
          directLinkStatus: 'Connecting 5GHz Wi-Fi Direct to ${peer.name}...',
        ),
      );
    }
    final clientConn = await _directBridge.connectDirectClient(
      ssid: hostReady.ssid!,
      psk: hostReady.psk!,
      frequencyMhz: hostReady.frequencyMhz,
      expectedGatewayIp: hostReady.hostIp,
    );
    if (clientConn == null) {
      throw "Could not join Direct 5GHz network from ${peer.name}.";
    }

    final targetHostIp = clientConn.gatewayIp.isNotEmpty
        ? clientConn.gatewayIp
        : (hostReady.hostIp ?? '192.168.49.1');
    final targetPort = hostReady.port > 0 ? hostReady.port : peer.port;

    await _sender.sendData(
      paths: itemsToSend,
      targetIp: targetHostIp,
      targetDeviceName: peer.name,
      senderDeviceName: state.deviceName,
      port: targetPort,
      useTls: plan.useTls,
      expectedPeerFingerprint: verifiedFingerprint,
      expectedPeerFingerprintProvider: () => verifiedFingerprint,
      localIdentity: identity,
      parallelStreams: plan.parallelStreams,
      onVerifyPeerFingerprint: verifiedFingerprint == null &&
              peer.fingerprintPrefix != null
          ? (actualFp) async => actualFp.toLowerCase().startsWith(
                peer.fingerprintPrefix!.toLowerCase(),
              )
          : null,
      onUpdate: onUpdate,
    );
  }

  @override
  Future<void> close() {
    _receiverSessionSeq++;
    _sendSessionToken++;
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    }
    if (_notifCompleter != null && !_notifCompleter!.isCompleted) {
      _notifCompleter!.complete(false);
    }
    if (_authCompleter != null && !_authCompleter!.isCompleted) {
      _authCompleter!.complete(false);
    }
    if (_pendingHostReadyCompleter != null &&
        !_pendingHostReadyCompleter!.isCompleted) {
      _pendingHostReadyCompleter!.completeError('TransferCubit closed');
    }
    _pendingHostReadyCompleter = null;
    _pendingHostReadyPeerId = null;
    _pendingHostReadyRequestId = null;
    _hostedDirectWatchdogTimer?.cancel();
    _hostedDirectWatchdogTimer = null;
    _activeHostedDirectSession = false;
    _peerPruneTimer?.cancel();
    _discoverySubscription?.cancel();
    _heartbeatSubscription?.cancel();
    _directEventsSubscription?.cancel();
    _peersSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _directBridge.stopBleDiscovery();
    _directBridge.stopDirectSession();
    _peerRegistry.dispose();
    discoveryService.dispose();
    _receiver.stop();
    _sender.cancel();
    _stopForegroundService();
    return super.close();
  }

  void cancelSending({String? reason}) {
    _sendSessionToken++;
    _sender.cancel(reason: reason);
    if (_pendingHostReadyCompleter != null &&
        !_pendingHostReadyCompleter!.isCompleted) {
      _pendingHostReadyCompleter!.completeError(reason ?? "Transfer Cancelled");
    }
    _pendingHostReadyCompleter = null;
    _pendingHostReadyPeerId = null;
    _pendingHostReadyRequestId = null;
    _pendingHostReadyExpectedFp = null;
    _pendingHostReadyExpectedFpPrefix = null;
    _directBridge.stopDirectSession();
    _safeEmit(
      state.copyWith(
        isTransferring: false,
        isDirectLinkConnecting: false,
        clearDirectLinkStatus: true,
        clearFeedback: true,
        model: TransferModel(
          status: reason ?? "Transfer Cancelled",
          transferred: state.model.transferred,
          totalSize: state.model.totalSize,
          progress: state.model.progress,
          fileName: state.model.fileName,
          phase: TransferPhase.cancelled,
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

  void cancelReceiving({String? reason}) {
    _receiver.cancelActiveTransfer(reason: reason);
    unawaited(_stopHostedDirectSession());
    if (state.authRequest != null) {
      resolveAuth(false);
    }
    _safeEmit(
      state.copyWith(
        clearFeedback: true,
        clearAuthRequest: true,
        model: TransferModel(
          status: reason ?? "Transfer Cancelled",
          transferred: state.model.transferred,
          totalSize: state.model.totalSize,
          progress: state.model.progress,
          fileName: state.model.fileName,
          phase: TransferPhase.cancelled,
        ),
      ),
    );
  }

  Future<void> openReceivedFolder() async {
    final folder = state.receiveFolder;
    if (folder == null) return;

    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [folder]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [folder]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [folder]);
      } else if (Platform.isAndroid) {
        // Use native MethodChannel for Android to avoid library issues
        const platform = MethodChannel('com.omarafifi.daphq/file_manager');
        await platform.invokeMethod('openFolder', {'path': folder});
      }
    } catch (e) {
      if (Platform.isAndroid) {
        _safeEmit(
          state.copyWith(
            errorMessage:
                "Could not open folder automatically. Please check: $folder",
          ),
        );
      } else {
        _safeEmit(state.copyWith(errorMessage: "Error opening folder: $e"));
      }
    }
  }

  void dismissProgress() {
    clearSelection(); // Aggressively clean cache and reset UI when user is done with the transfer session

    _safeEmit(
      state.copyWith(
        showProgressView: false,
        model: TransferModel(
          status: "",
          transferred: 0,
          totalSize: 0,
          progress: 0,
          fileName: "",
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

  Future<double> _getPathSizeMB(String path) async {
    try {
      if (await FileSystemEntity.isDirectory(path)) {
        int totalBytes = 0;
        await for (final entity in Directory(
          path,
        ).list(recursive: true, followLinks: false).handleError((_) {})) {
          if (entity is File) {
            try {
              totalBytes += await entity.length();
            } catch (_) {}
          }
        }
        return totalBytes / 1024 / 1024;
      } else {
        final file = File(path);
        if (await file.exists()) {
          final len = await file.length();
          return len / 1024 / 1024;
        }
      }
    } catch (_) {}
    return 0.0;
  }
}
