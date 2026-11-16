import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daphq/controllers/receiver_controller.dart';
import 'package:daphq/controllers/sender_controller.dart';
import 'package:daphq/controllers/v2_protocol_framing.dart';
import 'package:daphq/cubits/transfer_cubit.dart';
import 'package:daphq/fabric/ble_beacon_codec.dart';
import 'package:daphq/fabric/direct_native_bridge.dart';
import 'package:daphq/fabric/peer_models.dart';
import 'package:daphq/fabric/peer_registry.dart';
import 'package:daphq/fabric/smart_link_evaluator.dart';
import 'package:daphq/models/transfer_model.dart';
import 'package:daphq/security/device_identity_service.dart';
import 'package:daphq/security/trusted_devices_service.dart';
import 'package:daphq/services/discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeDirectNativeBridge extends DirectNativeBridge {
  final StreamController<DirectFabricEvent> controller =
      StreamController<DirectFabricEvent>.broadcast();

  LocalRadioCapabilities capabilities = const LocalRadioCapabilities(
    hasWifi: true,
    hasBle: true,
    canHostDirect5g: true,
    localPlatform: PeerPlatform.android,
  );
  bool bleDiscoveryStarted = false;
  bool stopDirectCalled = false;
  bool? lastPrefer5Ghz;
  String? lastStableTag;
  bool? lastAllow24GhzFallback;
  int startDirectHostCalls = 0;
  final List<bool> powerLockCalls = <bool>[];
  DirectHostInfo? hostToReturn = const DirectHostInfo(
    ssid: 'DIRECT-DQ-TEST',
    psk: 'secret1234',
    hostIp: '192.168.49.1',
    frequencyMhz: 5180,
  );
  DirectClientConnection? clientToReturn = const DirectClientConnection(
    localIp: '192.168.49.2',
    gatewayIp: '192.168.49.1',
  );
  final List<Map<String, dynamic>> gattExchanges = [];
  Map<String, dynamic>? gattResponse;
  List<String> hostClientsToReturn = const <String>[];
  List<String>? sharedEventOrderLog;
  Uint8List? lastBeaconPayload;

  @override
  Stream<DirectFabricEvent> get events => controller.stream;

  @override
  Future<LocalRadioCapabilities> getCapabilities() async => capabilities;

  @override
  Future<bool> startBleDiscovery({
    required Uint8List beaconPayload,
    required String peerId,
    required String peerName,
    required String fingerprint,
  }) async {
    bleDiscoveryStarted = true;
    lastBeaconPayload = beaconPayload;
    return true;
  }

  @override
  Future<void> stopBleDiscovery() async {
    bleDiscoveryStarted = false;
  }

  @override
  Future<DirectHostInfo?> startDirectHost({
    bool prefer5Ghz = true,
    String? stableTag,
    bool allow24GhzFallback = true,
  }) async {
    startDirectHostCalls++;
    lastPrefer5Ghz = prefer5Ghz;
    lastStableTag = stableTag;
    lastAllow24GhzFallback = allow24GhzFallback;
    return hostToReturn;
  }

  @override
  Future<DirectClientConnection?> connectDirectClient({
    required String ssid,
    required String psk,
    int? frequencyMhz,
    String? expectedGatewayIp,
  }) async => clientToReturn;

  @override
  Future<Map<String, dynamic>?> exchangeGattLink({
    required String bleAddress,
    required Map<String, dynamic> payload,
  }) async {
    gattExchanges.add({'bleAddress': bleAddress, 'payload': payload});
    return gattResponse;
  }

  @override
  Future<List<String>> getDirectHostClients() async => hostClientsToReturn;

  @override
  Future<void> stopDirectSession() async {
    stopDirectCalled = true;
    sharedEventOrderLog?.add('stopDirectSession');
  }

  @override
  Future<void> setTransferPowerLock(bool enabled) async {
    powerLockCalls.add(enabled);
  }

  void dispose() {
    controller.close();
  }
}

class _FakeSenderController extends SenderController {
  String? lastTargetIp;
  int? lastPort;
  bool? lastUseTls;
  int? lastParallelStreams;
  bool? lastListenReverse;
  String? lastExpectedFingerprint;
  String? Function()? lastExpectedFingerprintProvider;
  int? Function()? lastDirectFrequencyProvider;
  String? lastReverseAuthToken;
  int callCount = 0;
  int cancelCount = 0;
  Object? lastReverseSetupError;
  void Function(Object error)? onFailReverseSetup;
  bool triggerReverseListeningOnCustomSend = false;
  Future<void> Function(int callIndex)? onSend;
  Future<void> Function(int callIndex, Function(TransferModel) onUpdate)?
      onSendWithUpdate;

  @override
  Future<void> sendData({
    required List<String> paths,
    required String targetIp,
    required String targetDeviceName,
    required String senderDeviceName,
    required Function(TransferModel) onUpdate,
    int port = 62004,
    bool useTls = false,
    String? expectedPeerFingerprint,
    String? Function()? expectedPeerFingerprintProvider,
    DeviceIdentity? localIdentity,
    int parallelStreams = 1,
    bool listenForReverseReceiver = false,
    String? reverseAuthToken,
    Duration reverseConnectTimeout = const Duration(seconds: 30),
    void Function(int boundPort)? onReverseListening,
    int? Function()? directFrequencyProvider,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
  }) async {
    final idx = ++callCount;
    lastTargetIp = targetIp;
    lastPort = port;
    lastUseTls = useTls;
    lastParallelStreams = parallelStreams;
    lastListenReverse = listenForReverseReceiver;
    lastExpectedFingerprint = expectedPeerFingerprint;
    lastExpectedFingerprintProvider = expectedPeerFingerprintProvider;
    lastDirectFrequencyProvider = directFrequencyProvider;
    lastReverseAuthToken = reverseAuthToken;

    if (onSendWithUpdate != null) {
      if (listenForReverseReceiver && triggerReverseListeningOnCustomSend) {
        onReverseListening?.call(45678);
      }
      await onSendWithUpdate!(idx, onUpdate);
      return;
    }

    if (onSend != null) {
      await onSend!(idx);
      return;
    }

    if (listenForReverseReceiver) {
      onReverseListening?.call(45678);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    onUpdate(
      TransferModel(
        status: 'Transfer Complete',
        progress: 1.0,
        phase: TransferPhase.done,
      ),
    );
  }

  @override
  void failReverseSetup(Object error, [StackTrace? stackTrace]) {
    lastReverseSetupError = error;
    onFailReverseSetup?.call(error);
    super.failReverseSetup(error, stackTrace);
  }

  @override
  void cancel({String? reason}) {
    cancelCount++;
    super.cancel(reason: reason);
  }
}

class _FakeReceiverController extends ReceiverController {
  SecurityContext? lastTlsContext;
  Future<bool> Function(TransferAuthRequest request)? capturedAuthV2;
  Future<Map<String, dynamic>> Function(DirectControlRequest request)?
      capturedDirectControl;
  Function(TransferModel)? capturedOnUpdate;
  void Function()? capturedOnDone;
  void Function(int boundPort)? capturedOnListening;
  void Function(int frequencyMhz)? capturedOnPeerReportedFrequency;
  final List<Map<String, dynamic>> reverseCalls = [];
  bool cancelActiveCalled = false;
  String? cancelActiveReason;
  Future<void> Function()? onWaitForPendingRejection;
  List<String>? sharedEventOrderLog;

  @override
  Future<void> startReceiver({
    required String saveDirectory,
    required String deviceName,
    required Function(TransferModel) onUpdate,
    required Future<bool> Function(
      String senderIp,
      String senderDeviceName,
      int fileCount,
      double totalSizeMB,
    )
    onRequestAuth,
    required void Function() onDone,
    void Function()? onAuthDismissed,
    int port = 62004,
    void Function(int boundPort)? onListening,
    Future<int?> Function()? freeBytesProvider,
    SecurityContext? tlsContext,
    DeviceIdentity? localIdentity,
    Future<bool> Function(TransferAuthRequest request)? onRequestAuthV2,
    Future<Map<String, dynamic>> Function(DirectControlRequest request)?
        onDirectControlRequest,
    int? Function()? directFrequencyProvider,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    int maxParallelStreams = 4,
  }) async {
    lastTlsContext = tlsContext;
    capturedOnUpdate = onUpdate;
    capturedAuthV2 = onRequestAuthV2;
    capturedDirectControl = onDirectControlRequest;
    capturedOnDone = onDone;
    capturedOnListening = onListening;
    capturedOnPeerReportedFrequency = onPeerReportedFrequency;
  }

  @override
  Future<void> acceptReverseTransfer({
    required String senderIp,
    required int port,
    required String saveDirectory,
    required String deviceName,
    required Function(TransferModel) onUpdate,
    Future<bool> Function(
      String senderIp,
      String senderDeviceName,
      int fileCount,
      double totalSizeMB,
    )?
    onRequestAuth,
    Future<bool> Function(TransferAuthRequest request)? onRequestAuthV2,
    void Function()? onAuthDismissed,
    bool useTls = false,
    String? expectedSenderFingerprint,
    String? reverseAuthToken,
    DeviceIdentity? localIdentity,
    Future<int?> Function()? freeBytesProvider,
    int? directFrequencyMhz,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    int maxParallelStreams = 4,
    void Function()? onDone,
  }) async {
    capturedOnUpdate = onUpdate;
    capturedOnPeerReportedFrequency = onPeerReportedFrequency;
    reverseCalls.add({
      'senderIp': senderIp,
      'port': port,
      'useTls': useTls,
      'expectedSenderFingerprint': expectedSenderFingerprint,
      'reverseAuthToken': reverseAuthToken,
      'directFrequencyMhz': directFrequencyMhz,
    });
  }

  @override
  void cancelActiveTransfer({String? reason}) {
    cancelActiveCalled = true;
    cancelActiveReason = reason;
    sharedEventOrderLog?.add('cancelActiveTransfer');
  }

  @override
  Future<void> waitForPendingRejection() async {
    sharedEventOrderLog?.add('waitForPendingRejection_start');
    if (onWaitForPendingRejection != null) {
      await onWaitForPendingRejection!();
    }
    sharedEventOrderLog?.add('waitForPendingRejection_end');
  }

  @override
  void stop({String? reason}) {}
}

void main() {
  late Directory tempDir;
  late DeviceIdentityService identityService;
  late TrustedDevicesService trustedService;
  late _FakeDirectNativeBridge fakeBridge;
  late _FakeSenderController fakeSender;
  late _FakeReceiverController fakeReceiver;
  late PeerRegistry registry;
  late DiscoveryService discovery;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('daphq_cubit_fabric_');
    identityService = DeviceIdentityService(directoryProvider: () async => tempDir);
    trustedService = TrustedDevicesService(directoryProvider: () async => tempDir);
    fakeBridge = _FakeDirectNativeBridge();
    fakeSender = _FakeSenderController();
    fakeReceiver = _FakeReceiverController();
    registry = PeerRegistry();
    discovery = DiscoveryService();
  });

  tearDown(() async {
    fakeBridge.dispose();
    registry.dispose();
    discovery.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  TransferCubit buildCubit({DirectControlSenderFn? directControlSender}) {
    return TransferCubit(
      sender: fakeSender,
      receiver: fakeReceiver,
      discoveryService: discovery,
      identityService: identityService,
      trustedDevicesService: trustedService,
      directBridge: fakeBridge,
      peerRegistry: registry,
      directControlSender: directControlSender,
      autoStart: false,
    );
  }

  test('initializeFabric loads identity, trusted devices, and ingests BLE beacons', () async {
    final cubit = buildCubit();
    addTearDown(cubit.close);

    await cubit.initializeFabric(deviceName: 'Pixel 9');

    expect(cubit.state.localPeerId, isNotNull);
    expect(cubit.state.localFingerprint, hasLength(64));
    expect(fakeBridge.bleDiscoveryStarted, isTrue);

    final remoteFp = List.filled(64, 'a').join();
    final payload = BleBeaconCodec.encode(
      BleBeaconPayload(
        peerId: 'deadbeef01020304',
        fingerprintPrefix: remoteFp.substring(0, 16),
        transferPort: 62004,
        caps: const PeerCapabilities(
          directClientCapable: true,
          tlsSupported: true,
          multiStreamSupported: true,
          platform: PeerPlatform.windows,
        ),
      ),
    );
    fakeBridge.controller.add(
      DirectBleBeaconEvent(
        bleAddress: 'AA:BB:CC:DD:EE:FF',
        deviceName: 'WinBox',
        rssi: -45,
        payloadBytes: payload,
        decodedPayload: BleBeaconCodec.decode(payload),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(cubit.state.unifiedPeers.length, 1);
    expect(cubit.state.unifiedPeers.first.name, 'WinBox');
    expect(cubit.state.discoveredDevices.first.ip, 'ble:AA:BB:CC:DD:EE:FF');
  });

  test('trusted peer auto-accepts while fingerprint mismatch warns and prompts', () async {
    const remotePeerId = '0011223344556677';
    final expectedFp = List.filled(64, 'b').join();
    final mismatchedFp = List.filled(64, 'c').join();
    await trustedService.trustDevice(
      peerId: remotePeerId,
      displayName: 'Work PC',
      certFingerprint: expectedFp,
      platform: 'windows',
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'Phone');
    await cubit.startReceiver();

    final authHandler = fakeReceiver.capturedAuthV2!;
    expect(fakeReceiver.lastTlsContext, isNotNull);

    final trustedResult = await authHandler(
      TransferAuthRequest(
        senderIp: '192.168.1.50',
        senderDeviceName: 'Work PC',
        fileCount: 2,
        totalSizeMB: 12.0,
        senderPeerId: remotePeerId,
        senderFingerprint: expectedFp,
        isTls: true,
        isIdentityVerified: true,
      ),
    );
    expect(trustedResult, isTrue);
    expect(cubit.state.authRequest, isNull);

    // Spoofed/unverified sender claiming trusted peerId+fingerprint MUST NOT auto-accept
    final spoofFuture = authHandler(
      TransferAuthRequest(
        senderIp: '192.168.1.88',
        senderDeviceName: 'Work PC',
        fileCount: 1,
        totalSizeMB: 1.0,
        senderPeerId: remotePeerId,
        senderFingerprint: expectedFp,
        isTls: true,
        isIdentityVerified: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cubit.state.authRequest, isNotNull);
    expect(cubit.state.authRequest!.isTrustedPeer, isFalse);
    cubit.resolveAuth(false);
    expect(await spoofFuture, isFalse);

    final mismatchFuture = authHandler(
      TransferAuthRequest(
        senderIp: '192.168.1.99',
        senderDeviceName: 'Work PC',
        fileCount: 1,
        totalSizeMB: 5.0,
        senderPeerId: remotePeerId,
        senderFingerprint: mismatchedFp,
        isTls: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(cubit.state.authRequest, isNotNull);
    expect(cubit.state.authRequest!.isFingerprintMismatch, isTrue);
    expect(cubit.state.authRequest!.isTls, isTrue);

    cubit.resolveAuth(false);
    expect(await mismatchFuture, isFalse);
  });

  test('resolveAuth with trustPeer and revokeTrustedDevice update trustedDevices & UnifiedPeers', () async {
    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'Laptop');
    await cubit.startReceiver();

    final peerFp = List.filled(64, 'e').join();
    registry.upsertBleBeacon(
      BleBeaconPayload(
        peerId: 'ffeeddccbbaa9988',
        fingerprintPrefix: peerFp.substring(0, 16),
        transferPort: 62004,
        caps: const PeerCapabilities(
          tlsSupported: true,
          multiStreamSupported: true,
          platform: PeerPlatform.android,
        ),
      ),
      bleAddress: 'AA:BB:CC:DD:EE:99',
      deviceName: 'Office Phone',
    );

    final authFuture = fakeReceiver.capturedAuthV2!(
      TransferAuthRequest(
        senderIp: '192.168.1.77',
        senderDeviceName: 'Office Phone',
        fileCount: 1,
        totalSizeMB: 4.0,
        senderPeerId: 'ffeeddccbbaa9988',
        senderFingerprint: peerFp,
        isTls: true,
        isIdentityVerified: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await cubit.resolveAuth(true, trustPeer: true);
    expect(await authFuture, isTrue);

    expect(cubit.state.trustedDevices.length, 1);
    expect(cubit.state.unifiedPeers.first.isTrusted, isTrue);

    await cubit.revokeTrustedDevice('ffeeddccbbaa9988');
    expect(cubit.state.trustedDevices, isEmpty);
    expect(cubit.state.unifiedPeers.first.isTrusted, isFalse);
  });

  test('sendToPeer escalates BLE-only peer to Direct 5GHz Link + Reverse-Connect', () async {
    final sampleFile = File('${tempDir.path}/sample.txt');
    await sampleFile.writeAsString('hello direct fabric');

    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'Pixel 9');

    final remoteFp = List.filled(64, 'd').join();
    fakeBridge.gattResponse = {
      'ok': true,
      'peerId': '1122334455667788',
      'fp': remoteFp,
    };

    final blePeer = UnifiedPeer(
      peerId: '1122334455667788',
      name: 'Surface Laptop',
      platform: PeerPlatform.windows,
      bleAddress: '11:22:33:44:55:66',
      fingerprintPrefix: remoteFp.substring(0, 16),
      caps: const PeerCapabilities(
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenBle: DateTime.now(),
    );

    await cubit.sendToPeer(blePeer, paths: [sampleFile.path]);

    expect(fakeBridge.gattExchanges.length, 1);
    final sentPayload =
        fakeBridge.gattExchanges.first['payload'] as Map<String, dynamic>;
    expect(sentPayload['action'], 'joinHost');
    expect(sentPayload['ssid'], 'DIRECT-DQ-TEST');
    expect(sentPayload['port'], 45678);
    expect(sentPayload['reverseConnect'], isTrue);
    expect(fakeSender.lastUseTls, isTrue);
    expect(fakeSender.lastParallelStreams, 4);
    expect(fakeSender.lastListenReverse, isTrue);
    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('cancelSending followed immediately by new send does not let stale error clobber active transfer', () async {
    final sampleFile = File('${tempDir.path}/race.txt');
    await sampleFile.writeAsString('race-check');

    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'SenderBox');

    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    fakeSender.onSend = (idx) async {
      if (idx == 1) {
        await firstGate.future;
        throw const TransferSendException('Transfer Cancelled', TransferPhase.cancelled);
      }
      await secondGate.future;
    };

    final lanPeer = UnifiedPeer(
      peerId: 'aaaa222233334444',
      name: 'PeerLan',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.70',
      certFingerprint: List.filled(64, 'f').join(),
      caps: const PeerCapabilities(
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    final f1 = cubit.sendToPeer(lanPeer, paths: [sampleFile.path]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cubit.state.isTransferring, isTrue);

    cubit.cancelSending();
    expect(cubit.state.isTransferring, isFalse);

    final f2 = cubit.sendToPeer(lanPeer, paths: [sampleFile.path]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cubit.state.isTransferring, isTrue);

    // Now release the stale first send's error AFTER second transfer is active
    firstGate.completeError(
      const TransferSendException('Transfer Cancelled', TransferPhase.cancelled),
    );
    await f1;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Second transfer must STILL be marked active (never clobbered by stale token)
    expect(cubit.state.isTransferring, isTrue);

    secondGate.complete();
    await f2;
    expect(cubit.state.isTransferring, isFalse);
  });

  test('direct hostReady resolves via matching requestId even if BLE RPA rotated', () async {
    final sampleFile = File('${tempDir.path}/rpa.txt');
    await sampleFile.writeAsString('rpa-ok');

    final remoteFp = List.filled(64, '7').join();
    fakeBridge.gattResponse = {'ok': true, 'fp': remoteFp};
    fakeBridge.hostToReturn = null;
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: true,
      canHostDirect5g: false,
      localPlatform: PeerPlatform.windows,
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'WinSender');

    final blePeer = UnifiedPeer(
      peerId: '9988776655443322',
      name: 'AndroidRx',
      platform: PeerPlatform.android,
      bleAddress: 'AA:BB:CC:00:11:22',
      fingerprintPrefix: remoteFp.substring(0, 16),
      caps: const PeerCapabilities(
        direct5gHostCapable: true,
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.android,
      ),
      lastSeenBle: DateTime.now(),
    );

    final sendFuture = cubit.sendToPeer(blePeer, paths: [sampleFile.path]);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final reqId =
        (fakeBridge.gattExchanges.first['payload'] as Map<String, dynamic>)['requestId']
            as String;
    fakeBridge.controller.add(
      DirectGattLinkRequestEvent(
        requestId: reqId,
        peerId: 'rotated-different-peer-or-rpa',
        peerName: 'AndroidRx',
        action: 'hostReady',
        ssid: 'DIRECT-DQ-RPA',
        psk: 'pass1234',
        hostIp: '192.168.49.1',
        port: 62004,
        peerFingerprint: remoteFp,
      ),
    );

    await sendFuture;
    expect(fakeSender.lastTargetIp, '192.168.49.1');
    expect(fakeSender.lastUseTls, isTrue);
    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('DirectGattLinkRequestEvent preserves optional sourceBleAddress from native event', () {
    final evt = DirectNativeBridge.parseEvent({
      'type': 'gattLinkRequest',
      'requestId': 'req-1',
      'peerId': 'peer-1',
      'peerName': 'WinSender',
      'action': 'startHost',
      'port': 62004,
      'sourceBleAddress': 'AA:BB:CC:11:22:33',
    });
    expect(evt, isA<DirectGattLinkRequestEvent>());
    final req = evt! as DirectGattLinkRequestEvent;
    expect(req.sourceBleAddress, 'AA:BB:CC:11:22:33');
    expect(req.action, 'startHost');
  });

  test('incoming startHostAndWait uses sourceBleAddress fallback and stops direct GO when transfer finishes', () async {
    fakeBridge.gattResponse = {'ok': true};
    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'AndroidRx');

    // Note: sender was NOT previously in peerRegistry, so only sourceBleAddress is known.
    fakeBridge.controller.add(
      const DirectGattLinkRequestEvent(
        requestId: 'req-host-1',
        peerId: 'unseen-win-peer',
        peerName: 'WinSender',
        action: 'startHostAndWait',
        port: 62004,
        sourceBleAddress: 'DD:EE:FF:00:11:22',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakeBridge.gattExchanges, hasLength(1));
    expect(fakeBridge.gattExchanges.first['bleAddress'], 'DD:EE:FF:00:11:22');
    expect(
      (fakeBridge.gattExchanges.first['payload'] as Map<String, dynamic>)['action'],
      'hostReady',
    );
    expect(fakeBridge.stopDirectCalled, isFalse);

    // Completing the incoming transfer tears down the hosted Direct GO group.
    fakeReceiver.capturedOnDone?.call();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('incoming startHostAndWait stops direct GO immediately when hostReady GATT reply fails', () async {
    fakeBridge.gattResponse = null;
    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'AndroidRx');

    fakeBridge.controller.add(
      const DirectGattLinkRequestEvent(
        requestId: 'req-host-fail',
        peerId: 'unseen-win-peer',
        peerName: 'WinSender',
        action: 'startHostAndWait',
        port: 62004,
        sourceBleAddress: '11:22:33:44:55:66',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('always-on receiver completing Direct transfer tears down hosted GO without stopping receiver', () async {
    fakeBridge.gattResponse = {'ok': true};
    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'AndroidRx');

    fakeBridge.controller.add(
      const DirectGattLinkRequestEvent(
        requestId: 'req-host-keepalive',
        peerId: 'win-sender-peer',
        peerName: 'WinSender',
        action: 'startHostAndWait',
        port: 62004,
        sourceBleAddress: 'AA:11:22:33:44:55',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(cubit.state.isReceiving, isTrue);
    expect(fakeBridge.stopDirectCalled, isFalse);

    // Simulate incoming transfer becoming active and finishing while server keeps listening
    fakeReceiver.capturedOnUpdate?.call(
      TransferModel(
        status: 'Receiving...',
        fileName: 'clip.mp4',
        totalSize: 1.0,
        transferred: 0.5,
        progress: 0.5,
        phase: TransferPhase.receiving,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cubit.state.isReceivingActive, isTrue);

    fakeReceiver.capturedOnUpdate?.call(
      TransferModel(
        status: 'Transfer Complete',
        fileName: 'clip.mp4',
        totalSize: 1.0,
        transferred: 1.0,
        progress: 1.0,
        phase: TransferPhase.done,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fakeBridge.stopDirectCalled, isTrue);
    expect(cubit.state.isReceiving, isTrue);
    expect(cubit.state.isReceivingActive, isFalse);
  });

  test('unsolicited joinHost is ignored while another transfer is active', () async {
    final sampleFile = File('${tempDir.path}/busy_send.txt');
    await sampleFile.writeAsString('busy-send');
    final sendGate = Completer<void>();
    fakeSender.onSend = (_) => sendGate.future;

    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'LocalPhone');

    final peer = UnifiedPeer(
      peerId: 'lan-busy-peer',
      name: 'PeerLAN',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.50',
      caps: const PeerCapabilities(
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    final f = cubit.sendToPeer(peer, paths: [sampleFile.path]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(cubit.state.isTransferring, isTrue);

    fakeBridge.controller.add(
      const DirectGattLinkRequestEvent(
        requestId: 'req-unsolicited',
        peerId: 'rogue-peer',
        peerName: 'Rogue',
        action: 'joinHost',
        ssid: 'DIRECT-DQ-ROGUE',
        psk: 'pass1234',
        hostIp: '192.168.49.1',
        port: 62004,
        useReverseConnect: true,
        reverseToken: 'rogue-tok',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fakeReceiver.reverseCalls, isEmpty);

    sendGate.complete();
    await f;
  });

  test('cancelSending during direct hostReady wait aborts direct session and skips SenderController.sendData', () async {
    final sampleFile = File('${tempDir.path}/cancel_direct.txt');
    await sampleFile.writeAsString('cancel-me');

    final remoteFp = List.filled(64, '5').join();
    fakeBridge.gattResponse = {'ok': true, 'fp': remoteFp};
    fakeBridge.hostToReturn = null;
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: true,
      canHostDirect5g: false,
      localPlatform: PeerPlatform.windows,
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'WinSender');

    final blePeer = UnifiedPeer(
      peerId: '1122334455667788',
      name: 'AndroidRx',
      platform: PeerPlatform.android,
      bleAddress: 'AA:BB:CC:00:11:99',
      fingerprintPrefix: remoteFp.substring(0, 16),
      caps: const PeerCapabilities(
        direct5gHostCapable: true,
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.android,
      ),
      lastSeenBle: DateTime.now(),
    );

    final sendFuture = cubit.sendToPeer(blePeer, paths: [sampleFile.path]);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fakeBridge.gattExchanges, hasLength(1));
    cubit.cancelSending();
    await sendFuture;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(cubit.state.isTransferring, isFalse);
    expect(fakeBridge.stopDirectCalled, isTrue);
    expect(fakeSender.callCount, 0);
  });

  test('direct hostReady ignores wrong requestId and wrong peerFingerprint before accepting genuine reply', () async {
    final sampleFile = File('${tempDir.path}/hostready_sec.txt');
    await sampleFile.writeAsString('hostready-sec-ok');

    final remoteFp = List.filled(64, '7').join();
    final spoofFp = List.filled(64, 'e').join();
    fakeBridge.gattResponse = {'ok': true, 'fp': remoteFp};
    fakeBridge.hostToReturn = null;
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: true,
      canHostDirect5g: false,
      localPlatform: PeerPlatform.windows,
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'WinSender');

    final blePeer = UnifiedPeer(
      peerId: '9988776655443322',
      name: 'AndroidRx',
      platform: PeerPlatform.android,
      bleAddress: 'AA:BB:CC:00:11:22',
      fingerprintPrefix: remoteFp.substring(0, 16),
      caps: const PeerCapabilities(
        direct5gHostCapable: true,
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.android,
      ),
      lastSeenBle: DateTime.now(),
    );

    final sendFuture = cubit.sendToPeer(blePeer, paths: [sampleFile.path]);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final reqId =
        (fakeBridge.gattExchanges.first['payload'] as Map<String, dynamic>)['requestId']
            as String;
    expect(reqId.length, greaterThanOrEqualTo(32));

    // 1. Matching peerId but wrong requestId -> ignored
    fakeBridge.controller.add(
      DirectGattLinkRequestEvent(
        requestId: 'spoof-req-id',
        peerId: '9988776655443322',
        peerName: 'AndroidRx',
        action: 'hostReady',
        ssid: 'DIRECT-SPOOF-1',
        psk: 'pass1234',
        hostIp: '192.168.49.99',
        port: 62004,
        peerFingerprint: remoteFp,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fakeSender.callCount, 0);

    // 2. Matching requestId but mismatched peerFingerprint -> ignored
    fakeBridge.controller.add(
      DirectGattLinkRequestEvent(
        requestId: reqId,
        peerId: '9988776655443322',
        peerName: 'AndroidRx',
        action: 'hostReady',
        ssid: 'DIRECT-SPOOF-2',
        psk: 'pass1234',
        hostIp: '192.168.49.99',
        port: 62004,
        peerFingerprint: spoofFp,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fakeSender.callCount, 0);

    // 3. Genuine matching requestId & matching peerFingerprint -> accepted
    fakeBridge.controller.add(
      DirectGattLinkRequestEvent(
        requestId: reqId,
        peerId: '9988776655443322',
        peerName: 'AndroidRx',
        action: 'hostReady',
        ssid: 'DIRECT-DQ-VALID',
        psk: 'pass1234',
        hostIp: '192.168.49.1',
        port: 62004,
        peerFingerprint: remoteFp,
      ),
    );

    await sendFuture;
    expect(fakeSender.callCount, 1);
    expect(fakeSender.lastTargetIp, '192.168.49.1');
    expect(fakeSender.lastExpectedFingerprint, remoteFp);
  });

  test('LAN-triggered Direct 5GHz sends Windows -> Android via Android Host with zero Bluetooth or picker', () async {
    final sampleFile = File('${tempDir.path}/lan_direct_win.txt');
    await sampleFile.writeAsString('win-to-android-5g');

    final remoteFp = List.filled(64, '8').join();
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      localPlatform: PeerPlatform.windows,
    );
    fakeBridge.clientToReturn = const DirectClientConnection(
      localIp: '192.168.43.18',
      gatewayIp: '192.168.43.1',
      frequencyMhz: 5200,
    );

    final controlCalls = <Map<String, dynamic>>[];
    final cubit = buildCubit(
      directControlSender: ({
        required host,
        required port,
        required localIdentity,
        required localDeviceName,
        required localPort,
        required action,
        expectedPeerFingerprint,
        onVerifyPeerFingerprint,
        ssid,
        psk,
        hostIp,
        reverseConnect = false,
        frequencyMhz,
        reverseToken,
        connectTimeout = const Duration(seconds: 4),
        responseTimeout = const Duration(seconds: 22),
      }) async {
        controlCalls.add({
          'host': host,
          'port': port,
          'action': action,
          'reverseConnect': reverseConnect,
        });
        return <String, dynamic>{
          'ok': true,
          'ssid': 'DIRECT-DQ-ANDROID5G',
          'psk': 'Pass5G1234',
          'hostIp': '192.168.43.1',
          'port': 62004,
          'frequencyMhz': 0,
        };
      },
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'WinLaptop');
    expect(fakeBridge.bleDiscoveryStarted, isFalse);

    final androidLanPeer = UnifiedPeer(
      peerId: 'aaaa1111bbbb2222',
      name: 'Pixel 9 Pro',
      platform: PeerPlatform.android,
      lanIp: '192.168.1.45',
      certFingerprint: remoteFp,
      caps: const PeerCapabilities(
        direct5gHostCapable: true,
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.android,
      ),
      lastSeenLan: DateTime.now(),
    );

    await cubit.sendToPeer(androidLanPeer, paths: [sampleFile.path]);

    expect(controlCalls, hasLength(1));
    expect(controlCalls.first['host'], '192.168.1.45');
    expect(controlCalls.first['action'], 'startHostAndWait');
    expect(controlCalls.first['reverseConnect'], isFalse);
    expect(fakeBridge.gattExchanges, isEmpty);
    expect(fakeSender.lastTargetIp, '192.168.43.1');
    expect(fakeSender.lastUseTls, isTrue);
    expect(fakeSender.lastParallelStreams, 4);
    expect(fakeSender.lastDirectFrequencyProvider?.call(), 5200);
    expect(cubit.state.model.routeLabel, 'Direct 5GHz Wi-Fi');
    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('LAN-triggered Direct 5GHz sends Android -> Windows Reverse-Connect with zero Bluetooth', () async {
    final sampleFile = File('${tempDir.path}/lan_direct_and.txt');
    await sampleFile.writeAsString('android-to-win-5g');

    final remoteFp = List.filled(64, '9').join();
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      localPlatform: PeerPlatform.android,
    );

    final controlCalls = <Map<String, dynamic>>[];
    final cubit = buildCubit(
      directControlSender: ({
        required host,
        required port,
        required localIdentity,
        required localDeviceName,
        required localPort,
        required action,
        expectedPeerFingerprint,
        onVerifyPeerFingerprint,
        ssid,
        psk,
        hostIp,
        reverseConnect = false,
        frequencyMhz,
        reverseToken,
        connectTimeout = const Duration(seconds: 4),
        responseTimeout = const Duration(seconds: 15),
      }) async {
        controlCalls.add({
          'action': action,
          'ssid': ssid,
          'hostIp': hostIp,
          'reverseConnect': reverseConnect,
          'localPort': localPort,
        });
        return <String, dynamic>{'ok': true};
      },
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'Pixel 9');

    final winLanPeer = UnifiedPeer(
      peerId: 'cccc3333dddd4444',
      name: 'Surface Pro',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.88',
      certFingerprint: remoteFp,
      caps: const PeerCapabilities(
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    await cubit.sendToPeer(winLanPeer, paths: [sampleFile.path]);

    expect(controlCalls, hasLength(1));
    expect(controlCalls.first['action'], 'joinHost');
    expect(controlCalls.first['ssid'], 'DIRECT-DQ-TEST');
    expect(controlCalls.first['reverseConnect'], isTrue);
    expect(controlCalls.first['localPort'], 45678);
    expect(fakeSender.lastListenReverse, isTrue);
    expect(cubit.state.model.routeLabel, 'Direct 5GHz Wi-Fi');
  });

  test(
    'LAN-triggered Direct 5GHz prefers Android Host over Windows Host even when Windows canHostDirect5g is true',
    () async {
      final sampleFile = File('${tempDir.path}/android_host_preferred.txt');
      await sampleFile.writeAsString('android-first-payload');

      final remoteFp = List.filled(64, '5').join();
      fakeBridge.capabilities = const LocalRadioCapabilities(
        hasWifi: true,
        hasBle: false,
        canHostDirect5g: true,
        wifiHardwarePresent: true,
        wifiEnabled: true,
        localPlatform: PeerPlatform.android,
      );
      fakeBridge.hostToReturn = const DirectHostInfo(
        ssid: 'AndroidSoftAP_5G',
        psk: 'Pass556677',
        hostIp: '192.168.43.1',
        frequencyMhz: 0,
      );

      final controlCalls = <Map<String, dynamic>>[];
      final cubit = buildCubit(
        directControlSender: ({
          required host,
          required port,
          required localIdentity,
          required localDeviceName,
          required localPort,
          required action,
          expectedPeerFingerprint,
          onVerifyPeerFingerprint,
          ssid,
          psk,
          hostIp,
          reverseConnect = false,
          frequencyMhz,
          reverseToken,
          connectTimeout = const Duration(seconds: 4),
          responseTimeout = const Duration(seconds: 15),
        }) async {
          controlCalls.add({
            'action': action,
            'reverseConnect': reverseConnect,
            'frequencyMhz': frequencyMhz,
          });
          return <String, dynamic>{'ok': true, 'fp': remoteFp};
        },
      );
      addTearDown(cubit.close);
      await cubit.initializeFabric(deviceName: 'OnePlus 13R');

      final winPeerBoth5g = UnifiedPeer(
        peerId: 'aaaa1111bbbb2222',
        name: 'Omar-PC',
        platform: PeerPlatform.windows,
        lanIp: '192.168.1.99',
        certFingerprint: remoteFp,
        caps: const PeerCapabilities(
          direct5gHostCapable: true,
          directClientCapable: true,
          tlsSupported: true,
          multiStreamSupported: true,
          platform: PeerPlatform.windows,
        ),
        lastSeenLan: DateTime.now(),
      );

      await cubit.sendToPeer(winPeerBoth5g, paths: [sampleFile.path]);

      expect(fakeBridge.lastPrefer5Ghz, isTrue);
      expect(controlCalls.length, 1);
      expect(controlCalls.first['action'], 'joinHost');
      expect(controlCalls.first['reverseConnect'], isTrue);
      expect(controlCalls.first['frequencyMhz'], 0);
      expect(fakeSender.callCount, 1);
      expect(cubit.state.model.routeLabel, 'Direct Wi-Fi');
    },
  );

  test(
    'LAN-triggered Direct 5GHz falls back to Windows Host when Android lacks 5GHz host and upgrades routeLabel on peer frequency',
    () async {
      final sampleFile = File('${tempDir.path}/win_host_fallback.txt');
      await sampleFile.writeAsString('win-fallback-payload');

      final remoteFp = List.filled(64, '6').join();
      fakeBridge.capabilities = const LocalRadioCapabilities(
        hasWifi: true,
        hasBle: false,
        canHostDirect5g: true,
        wifiHardwarePresent: true,
        wifiEnabled: true,
        localPlatform: PeerPlatform.windows,
      );
      fakeBridge.hostToReturn = const DirectHostInfo(
        ssid: 'DIRECT-WIN-HOST',
        psk: 'WinPass99',
        hostIp: '192.168.137.1',
        frequencyMhz: 0,
      );
      fakeBridge.hostClientsToReturn = const ['192.168.137.77'];

      final controlCalls = <Map<String, dynamic>>[];
      final txCubit = buildCubit(
        directControlSender: ({
          required host,
          required port,
          required localIdentity,
          required localDeviceName,
          required localPort,
          required action,
          expectedPeerFingerprint,
          onVerifyPeerFingerprint,
          ssid,
          psk,
          hostIp,
          reverseConnect = false,
          frequencyMhz,
          reverseToken,
          connectTimeout = const Duration(seconds: 4),
          responseTimeout = const Duration(seconds: 15),
        }) async {
          controlCalls.add({
            'action': action,
            'reverseConnect': reverseConnect,
            'frequencyMhz': frequencyMhz,
          });
          return <String, dynamic>{'ok': true, 'fp': remoteFp};
        },
      );
      addTearDown(txCubit.close);
      await txCubit.initializeFabric(deviceName: 'Omar-PC');

      final androidClientOnly = UnifiedPeer(
        peerId: 'cccc4444dddd5555',
        name: 'LegacyAndroid',
        platform: PeerPlatform.android,
        lanIp: '192.168.1.77',
        certFingerprint: remoteFp,
        caps: const PeerCapabilities(
          direct5gHostCapable: false,
          directClientCapable: true,
          tlsSupported: true,
          multiStreamSupported: true,
          platform: PeerPlatform.android,
        ),
        lastSeenLan: DateTime.now(),
      );

      await txCubit.sendToPeer(androidClientOnly, paths: [sampleFile.path]);

      expect(controlCalls.length, 1);
      expect(controlCalls.first['action'], 'joinHost');
      expect(controlCalls.first['reverseConnect'], isFalse);
      expect(fakeSender.callCount, 1);
      expect(fakeSender.lastTargetIp, '192.168.137.77');
      expect(txCubit.state.model.routeLabel, 'Direct Wi-Fi');

      // Receiver side starts with host freq 0 ('Direct Wi-Fi') and upgrades to
      // 'Direct 5GHz Wi-Fi' once peer metadata reports measured RF frequency.
      txCubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
      await txCubit.startReceiver();
      final controlResp = await fakeReceiver.capturedDirectControl!(
        const DirectControlRequest(
          requestId: 'req-freq-upgrade-1',
          senderIp: '192.168.137.55',
          senderPeerId: '1122334455667788',
          senderDeviceName: 'OnePlus 13R',
          action: 'startHostAndWait',
          isIdentityVerified: true,
        ),
      );
      expect(controlResp['ok'], isTrue);

      fakeReceiver.capturedOnUpdate?.call(
        TransferModel(
          status: 'Receiving...',
          fileName: 'clip.mp4',
          totalSize: 1.0,
          transferred: 0.1,
          progress: 0.1,
          phase: TransferPhase.receiving,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(txCubit.state.model.routeLabel, 'Direct Wi-Fi');

      fakeReceiver.capturedOnPeerReportedFrequency?.call(5200);
      fakeReceiver.capturedOnUpdate?.call(
        TransferModel(
          status: 'Receiving...',
          fileName: 'clip.mp4',
          totalSize: 1.0,
          transferred: 0.4,
          progress: 0.4,
          phase: TransferPhase.receiving,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(txCubit.state.model.routeLabel, 'Direct 5GHz Wi-Fi');

      // Completion triggers async history logging + hosted Direct teardown;
      // routeLabel must remain 'Direct 5GHz Wi-Fi' on the finished card.
      fakeReceiver.capturedOnUpdate?.call(
        TransferModel(
          status: 'Transfer Complete',
          fileName: 'clip.mp4',
          totalSize: 1.0,
          transferred: 1.0,
          progress: 1.0,
          phase: TransferPhase.done,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(txCubit.state.model.routeLabel, 'Direct 5GHz Wi-Fi');
    },
  );

  test('pre-bytes Direct P2P failure falls back transparently to Router LAN, while cert mismatch never falls back', () async {
    final sampleFile = File('${tempDir.path}/fallback_direct.txt');
    await sampleFile.writeAsString('fallback-payload');

    final remoteFp = List.filled(64, '4').join();
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: false,
      localPlatform: PeerPlatform.windows,
    );
    fakeBridge.clientToReturn = null; // Simulate WlanConnect failure

    final controlActions = <String>[];
    final cubit = buildCubit(
      directControlSender: ({
        required host,
        required port,
        required localIdentity,
        required localDeviceName,
        required localPort,
        required action,
        expectedPeerFingerprint,
        onVerifyPeerFingerprint,
        ssid,
        psk,
        hostIp,
        reverseConnect = false,
        frequencyMhz,
        reverseToken,
        connectTimeout = const Duration(seconds: 4),
        responseTimeout = const Duration(seconds: 15),
      }) async {
        controlActions.add(action);
        return <String, dynamic>{
          'ok': true,
          'ssid': 'DIRECT-DQ-FAIL',
          'psk': 'SecretPass',
          'hostIp': '192.168.49.1',
          'port': 62004,
        };
      },
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'WinBox');

    final peer = UnifiedPeer(
      peerId: '2222333344445555',
      name: 'AndroidRx',
      platform: PeerPlatform.android,
      lanIp: '192.168.1.91',
      certFingerprint: remoteFp,
      caps: const PeerCapabilities(
        direct5gHostCapable: true,
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.android,
      ),
      lastSeenLan: DateTime.now(),
    );

    await cubit.sendToPeer(peer, paths: [sampleFile.path]);

    expect(controlActions, ['startHostAndWait', 'teardown']);
    expect(fakeSender.callCount, 1);
    expect(fakeSender.lastTargetIp, '192.168.1.91');
    expect(cubit.state.model.routeLabel, 'Wi-Fi Network');

    // Now verify MITM / HandshakeException from Direct control (even when Windows hosts) does NOT fall back to LAN!
    fakeSender.callCount = 0;
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      localPlatform: PeerPlatform.windows,
    );
    final securityCubit = buildCubit(
      directControlSender: ({
        required host,
        required port,
        required localIdentity,
        required localDeviceName,
        required localPort,
        required action,
        expectedPeerFingerprint,
        onVerifyPeerFingerprint,
        ssid,
        psk,
        hostIp,
        reverseConnect = false,
        frequencyMhz,
        reverseToken,
        connectTimeout = const Duration(seconds: 4),
        responseTimeout = const Duration(seconds: 15),
      }) async {
        throw const HandshakeException('Peer certificate fingerprint mismatch');
      },
    );
    addTearDown(securityCubit.close);
    await securityCubit.initializeFabric(deviceName: 'WinBox2');

    await securityCubit.sendToPeer(peer, paths: [sampleFile.path]);
    expect(fakeSender.callCount, 0);
    expect(securityCubit.state.model.phase, TransferPhase.failed);
  });

  test(
    'SenderController.failReverseSetup preserves non-cancelled failed phase and HandshakeException semantics',
    () async {
      final sampleFile = File('${tempDir.path}/fail_reverse_setup.txt');
      await sampleFile.writeAsString('reverse-setup-payload');

      final sender = SenderController();
      await expectLater(
        () => sender.sendData(
          paths: [sampleFile.path],
          targetIp: '0.0.0.0',
          targetDeviceName: 'Omar-PC',
          senderDeviceName: 'OnePlus 13R',
          port: 0,
          useTls: true,
          listenForReverseReceiver: true,
          reverseAuthToken: 'tok-fail-1',
          reverseConnectTimeout: const Duration(seconds: 5),
          onReverseListening: (_) {
            scheduleMicrotask(() {
              sender.failReverseSetup(
                'Direct 5GHz credentials were not returned by Omar-PC. (hostStartFailed)',
              );
            });
          },
          onUpdate: (_) {},
        ),
        throwsA(
          isA<TransferSendException>()
              .having((e) => e.phase, 'phase', TransferPhase.failed)
              .having((e) => e.message, 'message', contains('hostStartFailed')),
        ),
      );

      final secSender = SenderController();
      await expectLater(
        () => secSender.sendData(
          paths: [sampleFile.path],
          targetIp: '0.0.0.0',
          targetDeviceName: 'Omar-PC',
          senderDeviceName: 'OnePlus 13R',
          port: 0,
          useTls: true,
          listenForReverseReceiver: true,
          reverseAuthToken: 'tok-fail-2',
          reverseConnectTimeout: const Duration(seconds: 5),
          onReverseListening: (_) {
            scheduleMicrotask(() {
              secSender.failReverseSetup(
                const HandshakeException('Peer certificate mismatch'),
              );
            });
          },
          onUpdate: (_) {},
        ),
        throwsA(
          isA<TransferSendException>()
              .having((e) => e.phase, 'phase', TransferPhase.failed)
              .having((e) => e.message, 'message', contains('Security Alert')),
        ),
      );
    },
  );

  test(
    'reverse-connect pre-bytes Direct control failure falls back to Router LAN instead of Transfer Cancelled, while fingerprintMismatch aborts',
    () async {
      final sampleFile = File('${tempDir.path}/reverse_control_fallback.txt');
      await sampleFile.writeAsString('reverse-fallback-payload');

      final remoteFp = List.filled(64, '7').join();
      fakeBridge.capabilities = const LocalRadioCapabilities(
        hasWifi: true,
        hasBle: false,
        canHostDirect5g: false,
        wifiHardwarePresent: true,
        wifiEnabled: true,
        localPlatform: PeerPlatform.android,
      );

      final controlActions = <String>[];
      var returnedError = 'hostStartFailed';
      final cubit = buildCubit(
        directControlSender: ({
          required host,
          required port,
          required localIdentity,
          required localDeviceName,
          required localPort,
          required action,
          expectedPeerFingerprint,
          onVerifyPeerFingerprint,
          ssid,
          psk,
          hostIp,
          reverseConnect = false,
          frequencyMhz,
          reverseToken,
          connectTimeout = const Duration(seconds: 4),
          responseTimeout = const Duration(seconds: 15),
        }) async {
          controlActions.add(action);
          return <String, dynamic>{
            'ok': false,
            'error': returnedError,
          };
        },
      );
      addTearDown(cubit.close);
      await cubit.initializeFabric(deviceName: 'OnePlus 13R');

      late Completer<Object> reverseErrCompleter;
      fakeSender.triggerReverseListeningOnCustomSend = true;
      fakeSender.onFailReverseSetup = (err) {
        if (!reverseErrCompleter.isCompleted) {
          reverseErrCompleter.complete(err);
        }
      };
      fakeSender.onSendWithUpdate = (idx, onUpdate) async {
        if (idx == 1) {
          reverseErrCompleter = Completer<Object>();
          final err = await reverseErrCompleter.future.timeout(
            const Duration(seconds: 3),
          );
          final msg = 'Error: $err';
          onUpdate(TransferModel(status: msg, phase: TransferPhase.failed));
          throw TransferSendException(msg, TransferPhase.failed);
        }
        onUpdate(
          TransferModel(
            status: 'Transfer Complete',
            progress: 1.0,
            phase: TransferPhase.done,
          ),
        );
      };

      final winPeer = UnifiedPeer(
        peerId: '777788889999aaaa',
        name: 'Omar-PC',
        platform: PeerPlatform.windows,
        lanIp: '192.168.1.99',
        certFingerprint: remoteFp,
        caps: const PeerCapabilities(
          direct5gHostCapable: true,
          directClientCapable: true,
          tlsSupported: true,
          multiStreamSupported: true,
          platform: PeerPlatform.windows,
        ),
        lastSeenLan: DateTime.now(),
      );

      await cubit.sendToPeer(winPeer, paths: [sampleFile.path]);

      expect(fakeSender.cancelCount, 0);
      expect(
        fakeSender.lastReverseSetupError.toString(),
        contains('hostStartFailed'),
      );
      expect(fakeSender.callCount, 2);
      expect(fakeSender.lastTargetIp, '192.168.1.99');
      expect(cubit.state.model.phase, TransferPhase.done);
      expect(cubit.state.model.routeLabel, 'Wi-Fi Network');

      // Now verify error='fingerprintMismatch' from Direct control aborts without
      // Router LAN fallback.
      fakeSender.callCount = 0;
      returnedError = 'fingerprintMismatch';
      fakeSender.onSendWithUpdate = (idx, onUpdate) async {
        reverseErrCompleter = Completer<Object>();
        final err = await reverseErrCompleter.future.timeout(
          const Duration(seconds: 3),
        );
        final msg = 'Error: $err';
        onUpdate(TransferModel(status: msg, phase: TransferPhase.failed));
        throw TransferSendException(msg, TransferPhase.failed);
      };

      await cubit.sendToPeer(winPeer, paths: [sampleFile.path]);

      expect(fakeSender.callCount, 1);
      expect(cubit.state.model.phase, TransferPhase.failed);
      expect(cubit.state.model.status, contains('fingerprintMismatch'));
    },
  );

  test('DirectRadioStateEvent enabling BLE auto-starts BLE discovery and updates capabilities', () async {
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      localPlatform: PeerPlatform.android,
      bluetoothHardwarePresent: true,
      bluetoothEnabled: false,
      missingBlePermission: true,
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'Pixel 9');

    expect(fakeBridge.bleDiscoveryStarted, isFalse);
    expect(cubit.state.localRadioCapabilities?.missingBlePermission, isTrue);

    fakeBridge.controller.add(
      const DirectRadioStateEvent(
        hasWifi: true,
        hasBle: true,
        bleAdvertising: true,
        bleScanning: true,
        canHostDirect5g: true,
        wifiHardwarePresent: true,
        bluetoothHardwarePresent: true,
        wifiEnabled: true,
        bluetoothEnabled: true,
        missingWifiPermission: false,
        missingBlePermission: false,
        locationServiceEnabled: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(cubit.state.localRadioCapabilities?.hasBle, isTrue);
    expect(cubit.state.localRadioCapabilities?.missingBlePermission, isFalse);
    expect(fakeBridge.bleDiscoveryStarted, isTrue);
  });

  test('incoming LAN DirectControlRequest starts Direct host synchronously and rejects unverified requests', () async {
    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'AndroidHost');
    await cubit.startReceiver();

    final handler = fakeReceiver.capturedDirectControl!;
    final unverified = await handler(
      const DirectControlRequest(
        requestId: 'r-bad',
        senderIp: '192.168.1.33',
        senderPeerId: '1122334455667788',
        senderDeviceName: 'Spoof',
        action: 'startHostAndWait',
        isIdentityVerified: false,
      ),
    );
    expect(unverified['ok'], isFalse);
    expect(unverified['error'], 'unverifiedSender');

    final valid = await handler(
      const DirectControlRequest(
        requestId: 'r-ok',
        senderIp: '192.168.1.44',
        senderPeerId: '1122334455667788',
        senderDeviceName: 'WinTx',
        action: 'startHostAndWait',
        isIdentityVerified: true,
      ),
    );
    expect(valid['ok'], isTrue);
    expect(valid['ssid'], 'DIRECT-DQ-TEST');
    expect(valid['hostIp'], '192.168.49.1');
    expect(fakeBridge.stopDirectCalled, isFalse);

    fakeReceiver.capturedOnDone?.call();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('passes deterministic stableTag to startDirectHost and sets honest Direct routeLabel from frequencyMhz', () async {
    final sampleFile = File('${tempDir.path}/honest_freq.txt');
    await sampleFile.writeAsString('freq-check');

    final winPeer = UnifiedPeer(
      peerId: 'win-peer-aabbccdd',
      name: 'WinPeer',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.77',
      port: 62004,
      caps: const PeerCapabilities(
        tlsSupported: true,
        direct5gHostCapable: false,
        directClientCapable: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    fakeBridge.hostToReturn = const DirectHostInfo(
      ssid: 'DIRECT-DQ-112233',
      psk: 'secret1234',
      hostIp: '192.168.49.1',
      frequencyMhz: 2437,
    );

    final cubit = buildCubit(
      directControlSender: ({
        required String host,
        required int port,
        required DeviceIdentity localIdentity,
        required String localDeviceName,
        required int localPort,
        required String action,
        String? ssid,
        String? psk,
        String? hostIp,
        int? frequencyMhz,
        bool reverseConnect = false,
        String? reverseToken,
        String? expectedPeerFingerprint,
        Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
        Duration connectTimeout = const Duration(seconds: 4),
        Duration responseTimeout = const Duration(seconds: 22),
      }) async =>
          <String, dynamic>{'ok': true},
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'Pixel9Host');
    await cubit.sendToPeer(winPeer, paths: [sampleFile.path]);

    expect(
      fakeBridge.lastStableTag,
      equals(deriveStableDirectSsidTag(cubit.state.localPeerId)),
    );
    expect(fakeBridge.lastStableTag, isNotNull);
    expect(cubit.state.model.routeLabel, 'Direct 2.4GHz Wi-Fi');

    // Unknown/unreported frequency (0) must honestly label Direct Wi-Fi instead of 5GHz.
    fakeBridge.hostToReturn = const DirectHostInfo(
      ssid: 'DIRECT-DQ-112233',
      psk: 'secret1234',
      hostIp: '192.168.49.1',
      frequencyMhz: 0,
    );
    await cubit.sendToPeer(winPeer, paths: [sampleFile.path]);
    expect(cubit.state.model.routeLabel, 'Direct Wi-Fi');
  });

  test('uses client-measured frequencyMhz when host SoftAP reports 0', () async {
    final sampleFile = File('${tempDir.path}/softap_freq.txt');
    await sampleFile.writeAsString('softap-5g-payload');

    final remoteFp = List.filled(64, 'c').join();
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: false,
      localPlatform: PeerPlatform.windows,
    );
    fakeBridge.clientToReturn = const DirectClientConnection(
      localIp: '192.168.43.15',
      gatewayIp: '192.168.43.1',
      frequencyMhz: 5745,
    );

    final cubit = buildCubit(
      directControlSender: ({
        required host,
        required port,
        required localIdentity,
        required localDeviceName,
        required localPort,
        required action,
        expectedPeerFingerprint,
        onVerifyPeerFingerprint,
        ssid,
        psk,
        hostIp,
        reverseConnect = false,
        frequencyMhz,
        reverseToken,
        connectTimeout = const Duration(seconds: 4),
        responseTimeout = const Duration(seconds: 22),
      }) async =>
          <String, dynamic>{
            'ok': true,
            'ssid': 'LOHS-5G-HOTSPOT',
            'psk': 'HotspotPass99',
            'hostIp': '192.168.43.1',
            'port': 62004,
            'frequencyMhz': 0,
          },
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'WinClient');

    final androidPeer = UnifiedPeer(
      peerId: '9988776655443322',
      name: 'OnePlus 13R',
      platform: PeerPlatform.android,
      lanIp: '192.168.1.50',
      certFingerprint: remoteFp,
      caps: const PeerCapabilities(
        direct5gHostCapable: true,
        directClientCapable: true,
        tlsSupported: true,
        multiStreamSupported: true,
        platform: PeerPlatform.android,
      ),
      lastSeenLan: DateTime.now(),
    );

    await cubit.sendToPeer(androidPeer, paths: [sampleFile.path]);

    expect(fakeSender.lastTargetIp, '192.168.43.1');
    expect(cubit.state.model.routeLabel, 'Direct 5GHz Wi-Fi');
  });

  test('acquires transfer power lock and pauses discovery broadcasts during transfer, restoring on error', () async {
    final sampleFile = File('${tempDir.path}/power_lock.txt');
    await sampleFile.writeAsString('lock-payload');

    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: false,
      wifiHardwarePresent: true,
      wifiEnabled: true,
      localPlatform: PeerPlatform.android,
    );

    final peer = UnifiedPeer(
      peerId: 'lan-only-peer',
      name: 'LanPeer',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.99',
      port: 62004,
      caps: const PeerCapabilities(
        tlsSupported: true,
        direct5gHostCapable: false,
        directClientCapable: false,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    final observedInFlightLock = <bool>[];
    final observedInFlightPause = <bool>[];
    fakeSender.onSend = (_) async {
      observedInFlightLock.add(fakeBridge.powerLockCalls.last);
      observedInFlightPause.add(discovery.isBroadcastPaused);
      throw 'Simulated socket drop';
    };

    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'PixelSender');
    await cubit.sendToPeer(peer, paths: [sampleFile.path]);

    expect(observedInFlightLock, equals([true]));
    expect(observedInFlightPause, equals([true]));
    expect(fakeBridge.powerLockCalls, equals([true, false]));
    expect(discovery.isBroadcastPaused, isFalse);
  });

  test('stops immediately without Router LAN fallback when Windows receiver rejects Direct transfer', () async {
    final sampleFile = File('${tempDir.path}/declined.txt');
    await sampleFile.writeAsString('decline-payload');

    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      wifiHardwarePresent: true,
      wifiEnabled: true,
      localPlatform: PeerPlatform.android,
    );

    final windowsPeer = UnifiedPeer(
      peerId: 'win-peer-reject',
      name: 'Omar-PC',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.40',
      port: 62004,
      caps: const PeerCapabilities(
        tlsSupported: true,
        direct5gHostCapable: false,
        directClientCapable: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    fakeSender.onSendWithUpdate = (idx, onUpdate) async {
      onUpdate(
        TransferModel(
          status: 'Waiting for Omar-PC to accept...',
          phase: TransferPhase.waitingAuth,
        ),
      );
      final rejected = TransferModel(
        status: 'Transfer rejected by Omar-PC.',
        phase: TransferPhase.cancelled,
      );
      onUpdate(rejected);
      throw TransferSendException(rejected.status, TransferPhase.cancelled);
    };

    final cubit = buildCubit(
      directControlSender: ({
        required host,
        required port,
        required localIdentity,
        required localDeviceName,
        required localPort,
        required action,
        expectedPeerFingerprint,
        onVerifyPeerFingerprint,
        ssid,
        psk,
        hostIp,
        reverseConnect = false,
        frequencyMhz,
        reverseToken,
        connectTimeout = const Duration(seconds: 4),
        responseTimeout = const Duration(seconds: 22),
      }) async =>
          <String, dynamic>{'ok': true, 'fp': 'a' * 64},
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'PixelTx');
    await cubit.sendToPeer(windowsPeer, paths: [sampleFile.path]);

    expect(fakeSender.callCount, 1);
    expect(cubit.state.isTransferring, isFalse);
    expect(cubit.state.model.phase, TransferPhase.cancelled);
    expect(cubit.state.model.status, contains('Transfer rejected by Omar-PC'));
    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('falls back to Router LAN if pre-metadata reverse link drops before peer responds', () async {
    final sampleFile = File('${tempDir.path}/fallback_ok.txt');
    await sampleFile.writeAsString('fallback-payload');

    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      wifiHardwarePresent: true,
      wifiEnabled: true,
      localPlatform: PeerPlatform.android,
    );

    final windowsPeer = UnifiedPeer(
      peerId: 'win-peer-fallback',
      name: 'Omar-PC',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.40',
      port: 62004,
      caps: const PeerCapabilities(
        tlsSupported: true,
        direct5gHostCapable: false,
        directClientCapable: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    fakeSender.onSendWithUpdate = (idx, onUpdate) async {
      if (idx == 1) {
        onUpdate(
          TransferModel(
            status: 'Waiting for direct reverse link...',
            phase: TransferPhase.waitingAuth,
          ),
        );
        throw 'Direct reverse link timed out';
      }
      onUpdate(
        TransferModel(
          status: 'Transfer Complete',
          progress: 1.0,
          phase: TransferPhase.done,
        ),
      );
    };

    final cubit = buildCubit(
      directControlSender: ({
        required host,
        required port,
        required localIdentity,
        required localDeviceName,
        required localPort,
        required action,
        expectedPeerFingerprint,
        onVerifyPeerFingerprint,
        ssid,
        psk,
        hostIp,
        reverseConnect = false,
        frequencyMhz,
        reverseToken,
        connectTimeout = const Duration(seconds: 4),
        responseTimeout = const Duration(seconds: 22),
      }) async =>
          <String, dynamic>{'ok': true, 'fp': 'a' * 64},
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'PixelTx');
    await cubit.sendToPeer(windowsPeer, paths: [sampleFile.path]);

    expect(fakeSender.callCount, 2);
    expect(cubit.state.isTransferring, isFalse);
    expect(cubit.state.model.phase, TransferPhase.done);
  });

  test('cancelReceiving awaits waitForPendingRejection before tearing down hosted Direct Wi-Fi session', () async {
    final eventLog = <String>[];
    final rejectionGate = Completer<void>();
    fakeBridge.sharedEventOrderLog = eventLog;
    fakeReceiver.sharedEventOrderLog = eventLog;
    fakeReceiver.onWaitForPendingRejection = () => rejectionGate.future;

    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      localPlatform: PeerPlatform.windows,
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'Omar-PC');
    await cubit.startReceiver();

    final handler = fakeReceiver.capturedDirectControl!;
    final controlResp = await handler(
      const DirectControlRequest(
        requestId: 'req-cancel-order-1',
        senderIp: '192.168.1.45',
        senderPeerId: '1122334455667788',
        senderDeviceName: 'OnePlus 13R',
        action: 'startHostAndWait',
        isIdentityVerified: true,
      ),
    );
    expect(controlResp['ok'], isTrue);

    cubit.cancelReceiving(reason: 'Cancelled by Omar-PC');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fakeReceiver.cancelActiveCalled, isTrue);
    expect(fakeReceiver.cancelActiveReason, 'Cancelled by Omar-PC');
    expect(
      eventLog,
      containsAllInOrder(['cancelActiveTransfer', 'waitForPendingRejection_start']),
    );
    expect(fakeBridge.stopDirectCalled, isFalse);

    rejectionGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      eventLog,
      containsAllInOrder([
        'cancelActiveTransfer',
        'waitForPendingRejection_start',
        'waitForPendingRejection_end',
        'stopDirectSession',
      ]),
    );
    expect(fakeBridge.stopDirectCalled, isTrue);
  });

  test('startReceiver onListening propagates fallback transfer port to BLE beacon and direct host response', () async {
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: true,
      canHostDirect5g: true,
      localPlatform: PeerPlatform.windows,
    );

    final cubit = buildCubit();
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'Omar-PC');
    await cubit.startReceiver();

    expect(fakeReceiver.capturedOnListening, isNotNull);
    fakeReceiver.capturedOnListening!(42604);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(fakeBridge.lastBeaconPayload, isNotNull);
    final decodedBeacon = BleBeaconCodec.decode(fakeBridge.lastBeaconPayload!);
    expect(decodedBeacon?.transferPort, 42604);

    final controlResp = await fakeReceiver.capturedDirectControl!(
      const DirectControlRequest(
        requestId: 'req-fallback-port-1',
        senderIp: '192.168.137.45',
        senderPeerId: '1122334455667788',
        senderDeviceName: 'OnePlus 13R',
        action: 'startHostAndWait',
        isIdentityVerified: true,
      ),
    );
    expect(controlResp['ok'], isTrue);
    expect(controlResp['port'], 42604);
  });

  test('passes allow24GhzFallback=false and flips immediately to peer 5GHz host when local startDirectHost returns null', () async {
    final sampleFile = File('${tempDir.path}/flip_5g.bin');
    await sampleFile.writeAsString('flip-to-peer-5g-host');

    final winPeer = UnifiedPeer(
      peerId: 'win-peer-5ghost-01',
      name: 'Omar-PC',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.90',
      port: 62004,
      caps: const PeerCapabilities(
        tlsSupported: true,
        direct5gHostCapable: true,
        directClientCapable: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    // Local Android reports 5GHz capable initially, then startDirectHost fails 5GHz check.
    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: true,
      localPlatform: PeerPlatform.android,
    );
    fakeBridge.hostToReturn = null;
    fakeBridge.clientToReturn = const DirectClientConnection(
      localIp: '192.168.137.189',
      gatewayIp: '192.168.137.1',
      frequencyMhz: 5200,
    );

    final controlActions = <String>[];
    final cubit = buildCubit(
      directControlSender: ({
        required String host,
        required int port,
        required DeviceIdentity localIdentity,
        required String localDeviceName,
        required int localPort,
        required String action,
        String? ssid,
        String? psk,
        String? hostIp,
        int? frequencyMhz,
        bool reverseConnect = false,
        String? reverseToken,
        String? expectedPeerFingerprint,
        Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
        Duration connectTimeout = const Duration(seconds: 4),
        Duration responseTimeout = const Duration(seconds: 22),
      }) async {
        controlActions.add(action);
        return <String, dynamic>{
          'ok': true,
          'ssid': 'DIRECT-DQ-440FFD',
          'psk': 'secret5ghz',
          'hostIp': '192.168.137.1',
          'port': 62004,
          'frequencyMhz': 5200,
        };
      },
    );
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'OnePlus CPH2647');
    await cubit.sendToPeer(winPeer, paths: [sampleFile.path]);

    expect(fakeBridge.startDirectHostCalls, 1);
    expect(fakeBridge.lastAllow24GhzFallback, isFalse);
    expect(controlActions, equals(['startHostAndWait']));
    expect(cubit.state.model.routeLabel, 'Direct 5GHz Wi-Fi');
    expect(cubit.state.model.phase, TransferPhase.done);

    // Subsequent transfer skips local startDirectHost immediately.
    await cubit.sendToPeer(winPeer, paths: [sampleFile.path]);
    expect(fakeBridge.startDirectHostCalls, 1);
    expect(controlActions, equals(['startHostAndWait', 'startHostAndWait']));
  });

  test('preserves Transfer Complete card when background startReceiver resets receiver phase to idle', () async {
    final sampleFile = File('${tempDir.path}/done_preserve.txt');
    await sampleFile.writeAsString('preserve-complete-card');

    final winPeer = UnifiedPeer(
      peerId: 'win-peer-complete-1',
      name: 'Omar-PC',
      platform: PeerPlatform.windows,
      lanIp: '192.168.1.91',
      port: 62004,
      caps: const PeerCapabilities(
        tlsSupported: true,
        direct5gHostCapable: true,
        directClientCapable: true,
        multiStreamSupported: true,
        platform: PeerPlatform.windows,
      ),
      lastSeenLan: DateTime.now(),
    );

    fakeBridge.capabilities = const LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: false,
      localPlatform: PeerPlatform.android,
    );
    fakeBridge.clientToReturn = const DirectClientConnection(
      localIp: '192.168.137.189',
      gatewayIp: '192.168.137.1',
      frequencyMhz: 5200,
    );

    final cubit = buildCubit(
      directControlSender: ({
        required String host,
        required int port,
        required DeviceIdentity localIdentity,
        required String localDeviceName,
        required int localPort,
        required String action,
        String? ssid,
        String? psk,
        String? hostIp,
        int? frequencyMhz,
        bool reverseConnect = false,
        String? reverseToken,
        String? expectedPeerFingerprint,
        Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
        Duration connectTimeout = const Duration(seconds: 4),
        Duration responseTimeout = const Duration(seconds: 22),
      }) async =>
          <String, dynamic>{
            'ok': true,
            'ssid': 'DIRECT-DQ-440FFD',
            'psk': 'secret5ghz',
            'hostIp': '192.168.137.1',
            'port': 62004,
            'frequencyMhz': 5200,
          },
    );
    addTearDown(cubit.close);
    cubit.setReceiveFolder(tempDir.path, saveToPrefs: false);
    await cubit.initializeFabric(deviceName: 'OnePlus CPH2647');
    await cubit.startReceiver();
    await cubit.sendToPeer(winPeer, paths: [sampleFile.path]);

    expect(cubit.state.showProgressView, isTrue);
    expect(cubit.state.model.phase, TransferPhase.done);

    // Simulate Wi-Fi reconnect causing background startReceiver() idle emission.
    fakeReceiver.capturedOnUpdate!(
      TransferModel(
        status: 'Ready & Waiting as OnePlus CPH2647',
        phase: TransferPhase.idle,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(cubit.state.showProgressView, isTrue);
    expect(cubit.state.model.phase, TransferPhase.done);
    expect(cubit.state.model.status, 'Transfer Complete');
  });
}
