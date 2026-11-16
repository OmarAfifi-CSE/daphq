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
import '../controllers/v2_protocol_framing.dart'
    show DirectControlRequest, generateTransferSessionId, sendDirectControl;
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

typedef DirectControlSenderFn = Future<Map<String, dynamic>> Function({
  required String host,
  required int port,
  required DeviceIdentity localIdentity,
  required String localDeviceName,
  required int localPort,
  required String action,
  String? expectedPeerFingerprint,
  Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
  String? ssid,
  String? psk,
  String? hostIp,
  bool reverseConnect,
  int? frequencyMhz,
  String? reverseToken,
  Duration connectTimeout,
  Duration responseTimeout,
});

class TransferCubit extends Cubit<TransferState> {
  final SenderController _sender;
  final ReceiverController _receiver;
  final DiscoveryService discoveryService;
  final DeviceIdentityService _identityService;
  final TrustedDevicesService _trustedDevicesService;
  final DirectNativeBridge _directBridge;
  final SmartLinkEvaluator _linkEvaluator;
  final PeerRegistry _peerRegistry;
  final DirectControlSenderFn _directControlSender;

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
  bool _bleDiscoveryStarted = false;
  bool _isHandlingIncomingDirect = false;
  final Set<String> _activeLanIps = <String>{};
  Completer<DirectGattLinkRequestEvent>? _pendingHostReadyCompleter;
  String? _pendingHostReadyPeerId;
  String? _pendingHostReadyRequestId;
  String? _pendingHostReadyExpectedFp;
  String? _pendingHostReadyExpectedFpPrefix;
  bool _activeHostedDirectSession = false;
  bool _isStartingHostedDirect = false;
  Timer? _hostedDirectWatchdogTimer;
  String? _activeDirectRouteLabel;
  int? _activeDirectFrequencyMhz;
  int _activeListenPort = AppConstants.transferPort;
  bool _sendingIsolationActive = false;
  DateTime? _lastForegroundNotificationUpdate;
  final Set<String> _peersLackingDirect5gHost = <String>{};

  void _setActiveDirectFrequency(int? frequencyMhz) {
    if (frequencyMhz != null && frequencyMhz > 0) {
      _activeDirectFrequencyMhz = frequencyMhz;
    }
    _activeDirectRouteLabel =
        directRouteLabelForFrequency(_activeDirectFrequencyMhz ?? frequencyMhz);
  }
  bool _receivingIsolationActive = false;
  bool _appliedTransferIsolation = false;

  String? get _stableDirectSsidTag =>
      deriveStableDirectSsidTag(_localIdentity?.peerId ?? state.localPeerId);

  Future<void> _syncTransferIsolation({bool? sending, bool? receiving}) async {
    if (sending != null) _sendingIsolationActive = sending;
    if (receiving != null) _receivingIsolationActive = receiving;
    final bool desired = _sendingIsolationActive || _receivingIsolationActive;
    if (desired == _appliedTransferIsolation) return;
    _appliedTransferIsolation = desired;
    discoveryService.setBroadcastPaused(desired);
    await _directBridge.setTransferPowerLock(desired);
  }

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
    DirectControlSenderFn? directControlSender,
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
       _directControlSender = directControlSender ?? sendDirectControl,
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

    final caps = await _fetchNativeCapabilities();
    if (isClosed) return;

    if (!isClosed && _localIdentity != null) {
      emit(
        state.copyWith(
          localPeerId: _localIdentity!.peerId,
          localFingerprint: _localIdentity!.certFingerprint,
        ),
      );
    }

    await _applyLocalCapabilities(
      caps,
      deviceNameOverride: deviceName,
      restartBleIfNeeded: true,
    );

    _peerPruneTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (!isClosed) {
        _peerRegistry.pruneExpired();
      }
    });
  }

  Future<LocalRadioCapabilities> _fetchNativeCapabilities() async {
    try {
      return await _directBridge.getCapabilities();
    } catch (_) {
      return LocalRadioCapabilities.fallbackForPlatform(
        DirectNativeBridge.currentPlatform(),
      );
    }
  }

  /// Refreshes Wi-Fi, Bluetooth, and Nearby permissions from native OS adapters
  /// (e.g. after runtime permission prompts or returning from system settings)
  /// and automatically brings up BLE discovery when newly permitted.
  Future<void> refreshCapabilities({bool restartBleIfNeeded = true}) async {
    if (isClosed) return;
    final caps = await _fetchNativeCapabilities();
    if (isClosed) return;
    await _applyLocalCapabilities(
      caps,
      restartBleIfNeeded: restartBleIfNeeded,
    );
  }

  Future<void> _applyLocalCapabilities(
    LocalRadioCapabilities caps, {
    String? deviceNameOverride,
    bool restartBleIfNeeded = true,
  }) async {
    final prevHasBle = _localRadioCaps?.hasBle ?? false;
    final bool changed =
        _localRadioCaps != caps || state.localRadioCapabilities != caps;
    _localRadioCaps = caps;
    _localPeerCaps = PeerCapabilities(
      tlsSupported: true,
      direct5gHostCapable: caps.canHostDirect5g,
      directClientCapable: caps.canUseDirectWifi,
      multiStreamSupported: true,
      platform: caps.localPlatform,
    );

    if (changed && !isClosed) {
      emit(state.copyWith(localRadioCapabilities: caps));
    }

    if (!caps.hasBle) {
      _bleDiscoveryStarted = false;
    }

    final identity = _localIdentity;
    if (identity == null) return;

    discoveryService.updateAdvertisementMetadata(
      peerId: identity.peerId,
      certFingerprint: identity.certFingerprint,
      capabilities: _localPeerCaps,
      listenPort: _activeListenPort,
    );

    if (restartBleIfNeeded &&
        caps.hasBle &&
        (!prevHasBle || !_bleDiscoveryStarted)) {
      await _startBleIfReady(
        identity: identity,
        deviceName: deviceNameOverride ?? state.deviceName,
      );
    }
  }

  Future<void> _startBleIfReady({
    required DeviceIdentity identity,
    required String deviceName,
  }) async {
    try {
      final beacon = BleBeaconPayload(
        caps: _localPeerCaps,
        peerId: identity.peerId,
        fingerprintPrefix: identity.certFingerprint.substring(0, 16),
        transferPort: _activeListenPort,
      );
      final ok = await _directBridge.startBleDiscovery(
        beaconPayload: BleBeaconCodec.encode(beacon),
        peerId: identity.peerId,
        peerName: deviceName,
        fingerprint: identity.certFingerprint,
      );
      if (ok) {
        _bleDiscoveryStarted = true;
      }
    } catch (_) {}
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

  Future<void> revokeTrustedDevice(String peerId) async {
    try {
      await _trustedDevicesService.revokeDevice(peerId);
      await _refreshTrustedDevices();
    } catch (_) {}
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
      final caps = event.toCapabilities(DirectNativeBridge.currentPlatform());
      unawaited(
        _applyLocalCapabilities(caps, restartBleIfNeeded: true),
      );
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

  bool get _isBusyForIncomingDirect =>
      isClosed ||
      state.isTransferring ||
      state.isReceivingActive ||
      state.isDirectLinkConnecting ||
      _activeHostedDirectSession ||
      _isStartingHostedDirect ||
      _isHandlingIncomingDirect;

  Future<({bool allowed, String? trustedFingerprint})>
  _validateIncomingDirectTrust(String peerId, String? peerFingerprint) async {
    final normalizedPeerId = peerId.trim().toLowerCase();
    final trusted = normalizedPeerId.isNotEmpty
        ? await _trustedDevicesService.getDevice(normalizedPeerId)
        : null;
    if (trusted != null &&
        peerFingerprint != null &&
        peerFingerprint.trim().isNotEmpty &&
        trusted.certFingerprint.trim().toLowerCase() !=
            peerFingerprint.trim().toLowerCase()) {
      return (allowed: false, trustedFingerprint: null);
    }
    return (allowed: true, trustedFingerprint: trusted?.certFingerprint);
  }

  Future<Map<String, dynamic>> _handleDirectControlRequest(
    DirectControlRequest req,
  ) async {
    if (!req.isIdentityVerified) {
      return <String, dynamic>{'ok': false, 'error': 'unverifiedSender'};
    }
    if (req.action == 'teardown') {
      await _stopHostedDirectSession();
      return <String, dynamic>{'ok': true};
    }
    if (state.receiveFolder == null) {
      return <String, dynamic>{'ok': false, 'error': 'receiverFolderUnset'};
    }
    if (_isBusyForIncomingDirect) {
      return <String, dynamic>{'ok': false, 'error': 'busy'};
    }

    final trust = await _validateIncomingDirectTrust(
      req.senderPeerId,
      req.senderFingerprint,
    );
    if (!trust.allowed) {
      return <String, dynamic>{'ok': false, 'error': 'fingerprintMismatch'};
    }

    if (req.action == 'joinHost') {
      if (req.ssid == null || req.psk == null) {
        return <String, dynamic>{'ok': false, 'error': 'missingCredentials'};
      }
      unawaited(
        _handleIncomingJoinHost(
          DirectGattLinkRequestEvent(
            requestId: req.requestId,
            peerId: req.senderPeerId,
            peerName: req.senderDeviceName,
            peerFingerprint: req.senderFingerprint,
            action: 'joinHost',
            ssid: req.ssid,
            psk: req.psk,
            hostIp: req.hostIp,
            port: req.port,
            useReverseConnect: req.useReverseConnect,
            frequencyMhz: req.frequencyMhz,
            reverseToken: req.reverseToken,
          ),
        ),
      );
      return <String, dynamic>{'ok': true};
    }

    if (req.action == 'startHostAndWait') {
      _isStartingHostedDirect = true;
      _hostedDirectWatchdogTimer?.cancel();
      try {
        if (!state.isReceiving) {
          await startReceiver();
        }
        final senderPeer = _peerRegistry.getByPeerId(req.senderPeerId);
        final bool senderCanHost5g =
            senderPeer != null && senderPeer.caps.direct5gHostCapable;
        final hostInfo = await _directBridge.startDirectHost(
          prefer5Ghz: true,
          stableTag: _stableDirectSsidTag,
          allow24GhzFallback: !senderCanHost5g,
        );
        if (hostInfo == null) {
          if (senderCanHost5g) {
            final updatedCaps =
                _localRadioCaps?.copyWith(canHostDirect5g: false);
            _localRadioCaps = updatedCaps;
            if (updatedCaps != null) {
              unawaited(
                _applyLocalCapabilities(
                  updatedCaps,
                  restartBleIfNeeded: false,
                ),
              );
            }
            return <String, dynamic>{
              'ok': false,
              'error': 'direct5gUnsupported',
            };
          }
          return <String, dynamic>{'ok': false, 'error': 'directHostFailed'};
        }
        _activeHostedDirectSession = true;
        _setActiveDirectFrequency(hostInfo.frequencyMhz);
        _scheduleHostedDirectWatchdog();
        if (req.useReverseConnect && req.port > 0) {
          unawaited(
            _waitForHostedClientAndReverseAccept(
              port: req.port,
              peerName: req.senderDeviceName,
              expectedSenderFingerprint:
                  req.senderFingerprint ?? trust.trustedFingerprint,
              reverseToken: req.reverseToken,
              frequencyMhz: hostInfo.frequencyMhz,
            ),
          );
        }
        return <String, dynamic>{
          'ok': true,
          'ssid': hostInfo.ssid,
          'psk': hostInfo.psk,
          'hostIp': hostInfo.hostIp,
          'port': _activeListenPort,
          'frequencyMhz': hostInfo.frequencyMhz,
          'reverseConnect': req.useReverseConnect,
        };
      } catch (e) {
        await _stopHostedDirectSession();
        return <String, dynamic>{'ok': false, 'error': e.toString()};
      } finally {
        _isStartingHostedDirect = false;
      }
    }

    return <String, dynamic>{'ok': false, 'error': 'unknownAction'};
  }

  Future<void> _handleIncomingJoinHost(DirectGattLinkRequestEvent event) async {
    if (state.receiveFolder == null || event.ssid == null || event.psk == null) {
      return;
    }
    if (_isBusyForIncomingDirect) {
      return;
    }
    _isHandlingIncomingDirect = true;
    bool keepDirectSession = false;
    try {
      final trust = await _validateIncomingDirectTrust(
        event.peerId,
        event.peerFingerprint,
      );
      if (!trust.allowed) {
        return;
      }
      final expectedSenderFp = event.peerFingerprint ?? trust.trustedFingerprint;

      if (!event.useReverseConnect && !state.isReceiving) {
        await startReceiver();
      }
      _safeEmit(
        state.copyWith(
          isDirectLinkConnecting: true,
          directLinkStatus: 'Joining ${directRouteLabelForFrequency(event.frequencyMhz)} from ${event.peerName}...',
        ),
      );
      _setActiveDirectFrequency(event.frequencyMhz);
      final conn = await _directBridge.connectDirectClient(
        ssid: event.ssid!,
        psk: event.psk!,
        frequencyMhz: event.frequencyMhz,
        expectedGatewayIp: event.hostIp,
      );
      if (conn == null) {
        if (event.useReverseConnect) {
          _safeEmit(
            state.copyWith(
              errorMessage:
                  'Could not join Direct 5GHz link from ${event.peerName}.',
            ),
          );
        }
        return;
      }
      final int? resolvedFreq =
          (conn.frequencyMhz != null && conn.frequencyMhz! > 0)
              ? conn.frequencyMhz
              : event.frequencyMhz;
      _setActiveDirectFrequency(resolvedFreq);
      if (!event.useReverseConnect) {
        _activeHostedDirectSession = true;
        _scheduleHostedDirectWatchdog();
        keepDirectSession = true;
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
        directFrequencyMhz: resolvedFreq,
        onPeerReportedFrequency: _setActiveDirectFrequency,
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
      _isHandlingIncomingDirect = false;
      if (!keepDirectSession) {
        _activeDirectRouteLabel = null;
        _activeDirectFrequencyMhz = null;
        await _directBridge.stopDirectSession();
      }
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

  Future<String?> _waitForHostedClientIp({
    required bool Function() isAborted,
    Duration timeout = const Duration(seconds: 26),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!isClosed && !isAborted()) {
      final clients = await _directBridge.getDirectHostClients();
      if (clients.isNotEmpty) {
        return clients.first;
      }
      if (DateTime.now().isAfter(deadline)) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<void> _waitForHostedClientAndReverseAccept({
    required int port,
    required String peerName,
    String? expectedSenderFingerprint,
    String? reverseToken,
    int? frequencyMhz,
  }) async {
    try {
      final clientIp = await _waitForHostedClientIp(
        isAborted: () => !_activeHostedDirectSession,
      );
      if (clientIp == null ||
          isClosed ||
          !_activeHostedDirectSession ||
          state.receiveFolder == null) {
        await _stopHostedDirectSession();
        return;
      }
      final identity = _localIdentity ?? await _identityService.loadOrCreate();
      _localIdentity = identity;
      await _receiver.acceptReverseTransfer(
        senderIp: clientIp,
        port: port,
        saveDirectory: state.receiveFolder!,
        deviceName: state.deviceName,
        useTls: true,
        expectedSenderFingerprint: expectedSenderFingerprint,
        reverseAuthToken: reverseToken,
        localIdentity: identity,
        directFrequencyMhz: frequencyMhz,
        onPeerReportedFrequency: _setActiveDirectFrequency,
        onAuthDismissed: _handleAuthDismissed,
        onUpdate: _handleReceiverModelUpdate,
        onRequestAuthV2: _authorizeIncomingTransfer,
        onDone: _handleReceiverTransferDone,
      );
    } catch (_) {
      await _stopHostedDirectSession();
    } finally {
      if (!_activeHostedDirectSession) {
        await _directBridge.stopDirectSession();
      }
    }
  }

  Future<void> _stopHostedDirectSession() async {
    _hostedDirectWatchdogTimer?.cancel();
    _hostedDirectWatchdogTimer = null;
    if (!_activeHostedDirectSession) return;
    _activeHostedDirectSession = false;
    _activeDirectRouteLabel = null;
    _activeDirectFrequencyMhz = null;
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
      final hostInfo = await _directBridge.startDirectHost(
        prefer5Ghz: true,
        stableTag: _stableDirectSsidTag,
      );
      if (hostInfo == null) return;
      _activeHostedDirectSession = true;
      _setActiveDirectFrequency(hostInfo.frequencyMhz);

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
          'port': _activeListenPort,
          'reverseConnect': event.useReverseConnect,
          'frequencyMhz': hostInfo.frequencyMhz,
        },
      );
      if (resp == null || resp['ok'] == false) {
        await _stopHostedDirectSession();
        return;
      }
      _scheduleHostedDirectWatchdog();
      if (event.useReverseConnect && event.port > 0) {
        unawaited(
          _waitForHostedClientAndReverseAccept(
            port: event.port,
            peerName: event.peerName,
            expectedSenderFingerprint:
                event.peerFingerprint ?? trusted?.certFingerprint,
            reverseToken: event.reverseToken,
            frequencyMhz: hostInfo.frequencyMhz,
          ),
        );
      }
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
        if (state.isTransferring && !state.isDirectLinkConnecting) {
          cancelSending(reason: "No network connection. Transfer cancelled.");
        }
      }

      // If receiver was active (but not mid-transfer or negotiating/hosting direct link),
      // restart it to bind to new IP.
      if (state.isReceiving &&
          !state.isReceivingActive &&
          !state.isDirectLinkConnecting &&
          !_activeHostedDirectSession &&
          !_isStartingHostedDirect &&
          !_isHandlingIncomingDirect &&
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
      listenPort: _activeListenPort,
    );
  }

  Future<void> _startReceiverAutomatically() async {
    // Allow HomePage's post-frame startup permissions to begin before checking
    // storage/notification requirements so we don't collide with permission_handler.
    await Future.delayed(const Duration(milliseconds: 250));
    if (Platform.isAndroid) {
      await StartupPermissionCoordinator.waitUntilFinished();
    }

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
    await StartupPermissionCoordinator.waitUntilFinished();

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
    // Capture phase and Direct route label synchronously before async queue
    // or session teardown clears active Direct state prior to UI emission.
    final TransferPhase phase = model.phase != TransferPhase.idle
        ? model.phase
        : _receiver.currentPhase;
    final String? capturedDirectLabel =
        (_activeHostedDirectSession ||
            _isHandlingIncomingDirect ||
            state.isDirectLinkConnecting)
        ? (_activeDirectRouteLabel ?? 'Direct Wi-Fi')
        : null;
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
        final bool preserveVisibleOutcome =
            !isBusy &&
            !wasActive &&
            phase == TransferPhase.idle &&
            (state.isTransferring || state.showProgressView);
        if (preserveVisibleOutcome) {
          return;
        }
        final String? activeDirectLabel =
            (_activeHostedDirectSession ||
                _isHandlingIncomingDirect ||
                state.isDirectLinkConnecting)
            ? (_activeDirectRouteLabel ?? capturedDirectLabel ?? 'Direct Wi-Fi')
            : capturedDirectLabel;
        if (activeDirectLabel != null) {
          model.routeLabel = model.routeLabel ?? activeDirectLabel;
        }
        unawaited(_syncTransferIsolation(receiving: isBusy));
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
        final now = DateTime.now();
        final shouldThrottle = isBusy &&
            _lastForegroundNotificationUpdate != null &&
            now.difference(_lastForegroundNotificationUpdate!).inMilliseconds <
                1500;
        if (!shouldThrottle) {
          _lastForegroundNotificationUpdate = now;
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
              onListening: (boundPort) {
                if (boundPort <= 0 ||
                    myRxToken != _receiverSessionSeq ||
                    isClosed) {
                  return;
                }
                final bool changed = _activeListenPort != boundPort;
                _activeListenPort = boundPort;
                discoveryService.updateAdvertisementMetadata(
                  listenPort: boundPort,
                );
                if (changed && _bleDiscoveryStarted && identity != null) {
                  unawaited(
                    _startBleIfReady(
                      identity: identity,
                      deviceName: state.deviceName,
                    ),
                  );
                }
              },
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
              onDirectControlRequest: _handleDirectControlRequest,
              directFrequencyProvider: () => _activeDirectFrequencyMhz,
              onPeerReportedFrequency: _setActiveDirectFrequency,
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

      final files = await FilePicker.pickFiles(
        type: (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            ? FileType.any
            : type,
        initialDirectory: initialDirectory,
      );

      if (files.isNotEmpty) {
        await addSelectedPaths(
          files.map((file) => file.path).whereType<String>().toList(),
        );
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
      await _syncTransferIsolation(sending: true);
      final identity = _localIdentity ?? await _identityService.loadOrCreate();
      _localIdentity = identity;
      final localCaps =
          _localRadioCaps ??
          LocalRadioCapabilities.fallbackForPlatform(
            DirectNativeBridge.currentPlatform(),
          );

      peer = _peerRegistry.getByPeerId(peer.peerId) ?? peer;
      if (_peersLackingDirect5gHost.contains(peer.peerId) &&
          peer.caps.direct5gHostCapable) {
        peer = peer.copyWith(
          caps: peer.caps.copyWith(direct5gHostCapable: false),
        );
      }

      bool lanProbeHealthy = true;
      if (peer.hasLan && peer.hasBle && localCaps.hasBle) {
        lanProbeHealthy = await _probeLanHealthy(peer.lanIp!, peer.port);
      }

      if (mySendToken != _sendSessionToken || isClosed) return;

      final LinkPlan plan = _linkEvaluator.planTransfer(
        peer: peer,
        localCaps: localCaps,
        localPeerId: identity.peerId,
        lanProbeHealthy: lanProbeHealthy,
      );

      if (plan.strategy == LinkExecutionStrategy.unreachable) {
        throw plan.reason;
      }

      TransferModel decorateRoute(TransferModel model, String routeLabel) {
        model.routeLabel = model.routeLabel ?? routeLabel;
        return model;
      }

      Future<void> sendViaLan(String routeLabel) {
        final effectiveIp = peer.lanIp ?? targetIp;
        return _sender.sendData(
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
          onUpdate: (model) =>
              onTokenizedSenderUpdate(decorateRoute(model, routeLabel)),
        );
      }

      if (plan.strategy == LinkExecutionStrategy.lanTriggeredDirectP2p ||
          plan.strategy == LinkExecutionStrategy.bleTriggeredDirectP2p) {
        directSessionStarted = true;
        bool peerResponded = false;
        bool switchedWifi = false;
        bool remoteDirectSignaled = false;

        try {
          await _executeDirectP2pTransfer(
            peer: peer,
            itemsToSend: itemsToSend,
            plan: plan,
            localCaps: localCaps,
            identity: identity,
            onWifiSwitched: () => switchedWifi = true,
            onRemoteDirectSignaled: () => remoteDirectSignaled = true,
            onUpdate: (model) {
              if (model.phase == TransferPhase.sending ||
                  model.phase == TransferPhase.finalizing ||
                  model.phase == TransferPhase.done ||
                  model.phase == TransferPhase.cancelled ||
                  (model.phase == TransferPhase.waitingAuth &&
                      model.status.contains(' to accept'))) {
                peerResponded = true;
              }
              if (model.phase == TransferPhase.failed &&
                  !peerResponded &&
                  peer.hasLan &&
                  !model.status.startsWith('Security Alert:')) {
                return;
              }
              onTokenizedSenderUpdate(
                decorateRoute(model, _activeDirectRouteLabel ?? 'Direct Wi-Fi'),
              );
            },
          );
        } catch (directError) {
          final errText = directError.toString();
          final bool securityBlocked = directError is HandshakeException ||
              directError is TlsException ||
              errText.contains('Security Alert') ||
              errText.toLowerCase().contains('mismatch') ||
              errText.toLowerCase().contains('rejected');
          final bool cancelled = mySendToken != _sendSessionToken ||
              (directError is TransferSendException &&
                  directError.phase == TransferPhase.cancelled) ||
              state.model.phase == TransferPhase.cancelled;

          if (peerResponded || cancelled || securityBlocked || !peer.hasLan) {
            rethrow;
          }

          // Pre-bytes Direct setup failed: teardown direct state, wait briefly
          // for Router Wi-Fi recovery if needed, and transparently fall back to LAN TLS.
          _activeDirectRouteLabel = null;
          _activeDirectFrequencyMhz = null;
          await _directBridge.stopDirectSession();
          directSessionStarted = false;
          if (mySendToken != _sendSessionToken || isClosed) return;

          _safeEmit(
            state.copyWith(
              isDirectLinkConnecting: false,
              directLinkStatus: 'Switching to Wi-Fi network...',
            ),
          );

          peer = _peerRegistry.getByPeerId(peer.peerId) ?? peer;
          if (switchedWifi) {
            for (var attempt = 0; attempt < 6; attempt++) {
              if (mySendToken != _sendSessionToken || isClosed) return;
              peer = _peerRegistry.getByPeerId(peer.peerId) ?? peer;
              if (await _probeLanHealthy(peer.lanIp!, peer.port)) break;
              await Future<void>.delayed(const Duration(milliseconds: 400));
            }
          }

          if (remoteDirectSignaled) {
            await _sendDirectTeardownSignal(
              peer: peer,
              identity: identity,
              localCaps: localCaps,
            );
          }

          final fallbackLabel =
              SmartLinkEvaluator.isDirectHotspotOrP2pSubnetIp(peer.lanIp)
              ? 'Direct Hotspot'
              : 'Wi-Fi Network';
          await sendViaLan(fallbackLabel);
        }
      } else {
        final routeLabel =
            SmartLinkEvaluator.isDirectHotspotOrP2pSubnetIp(peer.lanIp)
            ? 'Direct Hotspot'
            : 'Wi-Fi Network';
        await sendViaLan(routeLabel);
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
                status: errorMsg,
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
      _activeDirectRouteLabel = null;
      await _syncTransferIsolation(sending: false);
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
      final now = DateTime.now();
      final bool isSendingBusy = model.phase == TransferPhase.sending;
      final bool shouldThrottle = isSendingBusy &&
          _lastForegroundNotificationUpdate != null &&
          now.difference(_lastForegroundNotificationUpdate!).inMilliseconds <
              1500;
      if (!shouldThrottle) {
        _lastForegroundNotificationUpdate = now;
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
  }

  Future<void> _sendDirectTeardownSignal({
    required UnifiedPeer peer,
    required DeviceIdentity identity,
    required LocalRadioCapabilities localCaps,
  }) async {
    final reqId = generateTransferSessionId();
    bool sent = false;
    if (peer.hasLan) {
      try {
        await _directControlSender(
          host: peer.lanIp!,
          port: peer.port,
          localIdentity: identity,
          localDeviceName: state.deviceName,
          localPort: _activeListenPort,
          action: 'teardown',
          expectedPeerFingerprint: peer.certFingerprint,
          onVerifyPeerFingerprint: peer.fingerprintPrefix != null
              ? (actualFp) async => actualFp.toLowerCase().startsWith(
                    peer.fingerprintPrefix!.toLowerCase(),
                  )
              : null,
          connectTimeout: const Duration(seconds: 2),
          responseTimeout: const Duration(seconds: 2),
        );
        sent = true;
      } catch (_) {}
    }
    final bleAddr = peer.bleAddress;
    if (!sent && bleAddr != null && bleAddr.isNotEmpty && localCaps.hasBle) {
      try {
        await _directBridge.exchangeGattLink(
          bleAddress: bleAddr,
          payload: <String, dynamic>{
            'requestId': reqId,
            'peerId': identity.peerId,
            'peerName': state.deviceName,
            'peerFingerprint': identity.certFingerprint,
            'action': 'teardown',
          },
        );
      } catch (_) {}
    }
  }

  Future<void> _executeDirectP2pTransfer({
    required UnifiedPeer peer,
    required List<String> itemsToSend,
    required LinkPlan plan,
    required LocalRadioCapabilities localCaps,
    required DeviceIdentity identity,
    required void Function() onWifiSwitched,
    void Function()? onRemoteDirectSignaled,
    required void Function(TransferModel) onUpdate,
  }) async {
    _activeDirectFrequencyMhz = null;
    _activeDirectRouteLabel = null;
    final bool preferLanControl =
        plan.strategy == LinkExecutionStrategy.lanTriggeredDirectP2p &&
        peer.hasLan;
    final String? bleAddr = peer.bleAddress;
    final bool canBleControl =
        bleAddr != null && bleAddr.isNotEmpty && localCaps.hasBle;

    if (!preferLanControl && !canBleControl) {
      throw 'No LAN or BLE control channel available for Direct 5GHz.';
    }

    final reqId = generateTransferSessionId();
    String? verifiedFingerprint = peer.certFingerprint;

    bool matchesPinnedOrPrefix(String fp) {
      final norm = fp.trim().toLowerCase();
      if (norm.length != 64) return true;
      final pinned = peer.certFingerprint?.trim().toLowerCase();
      if (pinned != null && pinned.isNotEmpty) return norm == pinned;
      final prefix = peer.fingerprintPrefix?.trim().toLowerCase();
      if (prefix != null && prefix.isNotEmpty) return norm.startsWith(prefix);
      return true;
    }

    Future<bool> verifyPeerCert(
      String actualFp, {
      Completer<void>? pendingJoin,
    }) async {
      if (verifiedFingerprint == null &&
          pendingJoin != null &&
          !pendingJoin.isCompleted) {
        await pendingJoin.future.timeout(
          const Duration(seconds: 25),
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
    }

    bool useReverseConnect = plan.useReverseConnect;

    Future<bool> runLocalHostDirectTransfer({
      required bool allowFallbackToPeer,
    }) async {
      _safeEmit(
        state.copyWith(
          isDirectLinkConnecting: true,
          directLinkStatus:
              'Setting up fast direct connection with ${peer.name}...',
        ),
      );
      final hostInfo = await _directBridge.startDirectHost(
        prefer5Ghz: true,
        stableTag: _stableDirectSsidTag,
        allow24GhzFallback: !allowFallbackToPeer,
      );
      if (hostInfo == null && allowFallbackToPeer) {
        final updatedCaps = _localRadioCaps?.copyWith(canHostDirect5g: false);
        _localRadioCaps = updatedCaps;
        if (updatedCaps != null) {
          unawaited(
            _applyLocalCapabilities(
              updatedCaps,
              restartBleIfNeeded: false,
            ),
          );
        }
        if (localCaps.localPlatform != PeerPlatform.android ||
            peer.platform != PeerPlatform.windows) {
          useReverseConnect = false;
        }
        return false;
      } else if (hostInfo == null) {
        throw 'Could not start a direct Wi-Fi connection on this device.';
      }
      _setActiveDirectFrequency(hostInfo.frequencyMhz);

      _safeEmit(
        state.copyWith(
          directLinkStatus: 'Connecting directly to ${peer.name}...',
        ),
      );

      final String? reverseToken =
          useReverseConnect ? generateTransferSessionId() : null;
      final Completer<void> joinHostDone = Completer<void>();

      Future<bool> dispatchJoinHost(int connectPort) async {
        try {
          bool signaled = false;
          String? observedFp;

          if (preferLanControl) {
            try {
              final lanResp = await _sendLanDirectControlWithRetry(
                peer: peer,
                send: (targetHost, controlPort) => _directControlSender(
                  host: targetHost,
                  port: controlPort,
                  localIdentity: identity,
                  localDeviceName: state.deviceName,
                  localPort: connectPort,
                  action: 'joinHost',
                  expectedPeerFingerprint: verifiedFingerprint,
                  onVerifyPeerFingerprint: verifiedFingerprint == null
                      ? (actualFp) async {
                          if (!matchesPinnedOrPrefix(actualFp)) return false;
                          observedFp = actualFp.toLowerCase();
                          return true;
                        }
                      : null,
                  ssid: hostInfo.ssid,
                  psk: hostInfo.psk,
                  hostIp: hostInfo.hostIp,
                  reverseConnect: useReverseConnect,
                  frequencyMhz: hostInfo.frequencyMhz,
                  reverseToken: reverseToken,
                  connectTimeout: const Duration(seconds: 4),
                  responseTimeout: const Duration(seconds: 5),
                ),
              );
              signaled = lanResp['ok'] == true;
            } catch (e) {
              if (e is HandshakeException || e is TlsException) rethrow;
              signaled = false;
            }
          }

          if (!signaled && canBleControl) {
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
                'port': connectPort,
                'reverseConnect': useReverseConnect,
                'reverseToken': ?reverseToken,
                'frequencyMhz': hostInfo.frequencyMhz,
              },
            );
            if (gattResp != null && gattResp['ok'] != false) {
              signaled = true;
              observedFp = (gattResp['fp'] as String?) ?? observedFp;
            }
          }

          if (!signaled) {
            if (useReverseConnect) {
              _sender.cancel(
                reason: 'Could not signal Direct 5GHz link to ${peer.name}.',
              );
            }
            return false;
          }
          onRemoteDirectSignaled?.call();

          if (observedFp != null && observedFp!.length == 64) {
            final normalizedFp = observedFp!.toLowerCase();
            final trusted = await _trustedDevicesService.getDevice(peer.peerId);
            if (trusted != null &&
                trusted.certFingerprint.trim().toLowerCase() != normalizedFp) {
              if (useReverseConnect) {
                _sender.cancel(
                  reason: 'Peer certificate mismatch for ${peer.name}.',
                );
              } else {
                throw HandshakeException(
                  'Peer certificate mismatch for ${peer.name}.',
                );
              }
              return false;
            }
            verifiedFingerprint = normalizedFp;
          }
          return true;
        } catch (e) {
          if (e is HandshakeException || e is TlsException) {
            if (!useReverseConnect) rethrow;
            _sender.cancel(
              reason: 'Security Alert: TLS certificate error for ${peer.name}.',
            );
            return false;
          }
          if (useReverseConnect) {
            _sender.cancel(
              reason: 'Could not signal Direct 5GHz link to ${peer.name}.',
            );
          }
          return false;
        } finally {
          if (!joinHostDone.isCompleted) {
            joinHostDone.complete();
          }
        }
      }

      if (useReverseConnect) {
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
          reverseConnectTimeout: const Duration(seconds: 35),
          onReverseListening: (boundPort) {
            unawaited(dispatchJoinHost(boundPort));
          },
          onVerifyPeerFingerprint: (actualFp) =>
              verifyPeerCert(actualFp, pendingJoin: joinHostDone),
          directFrequencyProvider: () => _activeDirectFrequencyMhz,
          onPeerReportedFrequency: _setActiveDirectFrequency,
          onUpdate: onUpdate,
        );
      } else {
        final signaled = await dispatchJoinHost(_activeListenPort);
        if (!signaled) {
          throw 'Could not signal Direct 5GHz link to ${peer.name}.';
        }
        _safeEmit(
          state.copyWith(
            directLinkStatus: 'Connecting directly to ${peer.name}...',
          ),
        );
        final int activeSendToken = _sendSessionToken;
        final clientIp = await _waitForHostedClientIp(
          isAborted: () => _sendSessionToken != activeSendToken,
        );
        if (clientIp == null) {
          throw '${peer.name} did not join the Direct 5GHz link in time.';
        }
        onWifiSwitched();
        await _sender.sendData(
          paths: itemsToSend,
          targetIp: clientIp,
          targetDeviceName: peer.name,
          senderDeviceName: state.deviceName,
          port: peer.port > 0 ? peer.port : AppConstants.transferPort,
          useTls: plan.useTls,
          expectedPeerFingerprint: verifiedFingerprint,
          expectedPeerFingerprintProvider: () => verifiedFingerprint,
          localIdentity: identity,
          parallelStreams: plan.parallelStreams,
          onVerifyPeerFingerprint: (actualFp) => verifyPeerCert(actualFp),
          directFrequencyProvider: () => _activeDirectFrequencyMhz,
          onPeerReportedFrequency: _setActiveDirectFrequency,
          onUpdate: onUpdate,
        );
      }
      return true;
    }

    if (plan.shouldLocalHostDirectGroup) {
      if (await runLocalHostDirectTransfer(
        allowFallbackToPeer: peer.caps.direct5gHostCapable,
      )) {
        return;
      }
    }

    // Peer hosts the Direct AP/GO (e.g. Windows 5GHz Mobile Hotspot when Android
    // sends to Windows, or Android GO when an offline Windows PC sends to Android).
    _safeEmit(
      state.copyWith(
        isDirectLinkConnecting: true,
        directLinkStatus:
            'Setting up fast direct connection with ${peer.name}...',
      ),
    );

    Future<({DirectClientConnection conn, String? fallbackHostIp, int targetPort})>
    requestAndJoinPeerHost({
      required int listenPort,
      String? reverseToken,
    }) async {
      String? ssid;
      String? psk;
      String? hostIp;
      int targetPort = peer.port;
      int? freqMhz;

      String? lanErrorReason;
      if (preferLanControl) {
        try {
          final lanResp = await _sendLanDirectControlWithRetry(
            peer: peer,
            send: (targetHost, controlPort) => _directControlSender(
              host: targetHost,
              port: controlPort,
              localIdentity: identity,
              localDeviceName: state.deviceName,
              localPort: listenPort,
              action: 'startHostAndWait',
              expectedPeerFingerprint: verifiedFingerprint,
              onVerifyPeerFingerprint: verifiedFingerprint == null
                  ? (actualFp) async {
                      if (!matchesPinnedOrPrefix(actualFp)) return false;
                      verifiedFingerprint = actualFp.toLowerCase();
                      return true;
                    }
                  : null,
              reverseConnect: plan.useReverseConnect,
              reverseToken: reverseToken,
              connectTimeout: const Duration(seconds: 4),
              responseTimeout: const Duration(seconds: 22),
            ),
          );
          if (lanResp['ok'] == true &&
              lanResp['ssid'] is String &&
              lanResp['psk'] is String) {
            ssid = lanResp['ssid'] as String;
            psk = lanResp['psk'] as String;
            hostIp = lanResp['hostIp'] as String?;
            targetPort = (lanResp['port'] as num?)?.toInt() ?? peer.port;
            freqMhz = (lanResp['frequencyMhz'] as num?)?.toInt();
          } else {
            final err = lanResp['error'];
            if (err is String && err.trim().isNotEmpty) {
              lanErrorReason = err.trim();
            }
          }
        } catch (e) {
          if (e is HandshakeException || e is TlsException) rethrow;
          lanErrorReason = e.toString();
        }
      }

      if (ssid == null && canBleControl) {
        _pendingHostReadyPeerId = peer.peerId.trim().toLowerCase();
        _pendingHostReadyRequestId = reqId;
        _pendingHostReadyExpectedFp = peer.certFingerprint?.trim().toLowerCase();
        _pendingHostReadyExpectedFpPrefix = peer.fingerprintPrefix
            ?.trim()
            .toLowerCase();
        final hostReadyCompleter = Completer<DirectGattLinkRequestEvent>();
        hostReadyCompleter.future.catchError(
          (_) => DirectGattLinkRequestEvent(
            requestId: reqId,
            peerId: peer.peerId,
            peerName: peer.name,
            action: 'hostReady',
          ),
        );
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
              'port': listenPort,
              'reverseConnect': plan.useReverseConnect,
              'reverseToken': ?reverseToken,
            },
          );
          if (gattResp == null || gattResp['ok'] == false) {
            throw 'Could not reach ${peer.name}. Make sure both devices are nearby and unlocked.';
          }
          final fp = (gattResp['fp'] as String?)?.trim().toLowerCase();
          if (fp != null && fp.length == 64) {
            if (!matchesPinnedOrPrefix(fp)) {
              throw HandshakeException(
                'Peer certificate mismatch for ${peer.name}.',
              );
            }
            verifiedFingerprint = fp;
            _pendingHostReadyExpectedFp = fp;
          }

          hostReady = await hostReadyCompleter.future.timeout(
            const Duration(seconds: 22),
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
          if (!matchesPinnedOrPrefix(hostReady.peerFingerprint!)) {
            throw HandshakeException(
              'Peer certificate mismatch for ${peer.name}.',
            );
          }
          verifiedFingerprint = hostReady.peerFingerprint!.toLowerCase();
        }

        ssid = hostReady.ssid;
        psk = hostReady.psk;
        hostIp = hostReady.hostIp;
        if (hostReady.port > 0) targetPort = hostReady.port;
        freqMhz = hostReady.frequencyMhz;
      }

      if (ssid == null || psk == null) {
        final detail = (lanErrorReason != null && lanErrorReason.isNotEmpty)
            ? ' ($lanErrorReason)'
            : '';
        throw 'Could not establish a direct connection with ${peer.name}.$detail';
      }
      onRemoteDirectSignaled?.call();

      _setActiveDirectFrequency(freqMhz);
      _safeEmit(
        state.copyWith(
          directLinkStatus: 'Connecting directly to ${peer.name}...',
        ),
      );
      onWifiSwitched();
      final clientConn = await _directBridge.connectDirectClient(
        ssid: ssid,
        psk: psk,
        frequencyMhz: freqMhz,
        expectedGatewayIp: hostIp,
      );
      if (clientConn == null) {
        throw 'Could not connect to ${peer.name}\'s direct Wi-Fi.';
      }
      _setActiveDirectFrequency(clientConn.frequencyMhz ?? freqMhz);
      return (conn: clientConn, fallbackHostIp: hostIp, targetPort: targetPort);
    }

    if (useReverseConnect) {
      final reverseToken = generateTransferSessionId();
      final joinDone = Completer<void>();
      await _sender.sendData(
        paths: itemsToSend,
        targetIp: peer.lanIp ?? '0.0.0.0',
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
        reverseConnectTimeout: const Duration(seconds: 35),
        onReverseListening: (boundPort) {
          unawaited(() async {
            try {
              await requestAndJoinPeerHost(
                listenPort: boundPort,
                reverseToken: reverseToken,
              );
            } catch (e, st) {
              _sender.failReverseSetup(e, st);
            } finally {
              if (!joinDone.isCompleted) {
                joinDone.complete();
              }
            }
          }());
        },
        onVerifyPeerFingerprint: (actualFp) =>
            verifyPeerCert(actualFp, pendingJoin: joinDone),
        directFrequencyProvider: () => _activeDirectFrequencyMhz,
        onPeerReportedFrequency: _setActiveDirectFrequency,
        onUpdate: onUpdate,
      );
      return;
    }

    late final ({DirectClientConnection conn, String? fallbackHostIp, int targetPort})
        joined;
    try {
      joined = await requestAndJoinPeerHost(
        listenPort: _activeListenPort,
      );
    } catch (e) {
      final errStr = e.toString();
      if (!plan.shouldLocalHostDirectGroup &&
          localCaps.canHostDirect5g &&
          (errStr.contains('direct5gUnsupported') ||
              errStr.contains('directHostFailed'))) {
        _peersLackingDirect5gHost.add(peer.peerId);
        await runLocalHostDirectTransfer(allowFallbackToPeer: false);
        return;
      }
      rethrow;
    }
    final targetHostIp = joined.conn.gatewayIp.isNotEmpty
        ? joined.conn.gatewayIp
        : (joined.fallbackHostIp ?? '192.168.49.1');

    await _sender.sendData(
      paths: itemsToSend,
      targetIp: targetHostIp,
      targetDeviceName: peer.name,
      senderDeviceName: state.deviceName,
      port: joined.targetPort,
      useTls: plan.useTls,
      expectedPeerFingerprint: verifiedFingerprint,
      expectedPeerFingerprintProvider: () => verifiedFingerprint,
      localIdentity: identity,
      parallelStreams: plan.parallelStreams,
      onVerifyPeerFingerprint: (actualFp) => verifyPeerCert(actualFp),
      directFrequencyProvider: () => _activeDirectFrequencyMhz,
      onPeerReportedFrequency: _setActiveDirectFrequency,
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
    _activeDirectRouteLabel = null;
    unawaited(_syncTransferIsolation(sending: false, receiving: false));
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
    _activeDirectRouteLabel = null;
    _activeDirectFrequencyMhz = null;
    _directBridge.stopDirectSession();
    unawaited(_syncTransferIsolation(sending: false));
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
    unawaited(
      _receiver.waitForPendingRejection().whenComplete(() {
        if (!isClosed &&
            _activeHostedDirectSession &&
            !state.isReceivingActive &&
            !state.isTransferring) {
          unawaited(_stopHostedDirectSession());
        }
      }),
    );
    unawaited(_syncTransferIsolation(receiving: false));
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

  /// Sends a Direct Wi-Fi LAN control request, retrying briefly on transient
  /// socket/timeout errors (e.g. while Android finishes re-associating with
  /// the router Wi-Fi right after an earlier Direct session).
  Future<Map<String, dynamic>> _sendLanDirectControlWithRetry({
    required UnifiedPeer peer,
    required Future<Map<String, dynamic>> Function(String host, int port) send,
    int maxAttempts = 3,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      final latestPeer = _peerRegistry.getByPeerId(peer.peerId);
      final targetIp =
          (latestPeer?.lanIp != null && latestPeer!.lanIp!.isNotEmpty)
              ? latestPeer.lanIp!
              : peer.lanIp!;
      final targetPort = latestPeer?.port ?? peer.port;
      try {
        return await send(targetIp, targetPort);
      } on HandshakeException {
        rethrow;
      } on TlsException {
        rethrow;
      } catch (e) {
        final isTransient = e is SocketException || e is TimeoutException;
        if (!isTransient || attempt + 1 >= maxAttempts || isClosed) {
          rethrow;
        }
        await Future<void>.delayed(retryDelay);
        if (isClosed) {
          rethrow;
        }
      }
    }
    throw StateError('LAN direct control retries exhausted');
  }
}
