import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daphq/controllers/receiver_controller.dart';
import 'package:daphq/controllers/sender_controller.dart';
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
    return true;
  }

  @override
  Future<void> stopBleDiscovery() async {
    bleDiscoveryStarted = false;
  }

  @override
  Future<DirectHostInfo?> startDirectHost({bool prefer5Ghz = true}) async =>
      hostToReturn;

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
  Future<void> stopDirectSession() async {
    stopDirectCalled = true;
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
  String? lastReverseAuthToken;
  int callCount = 0;
  int cancelCount = 0;
  Future<void> Function(int callIndex)? onSend;

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
    void Function(int boundPort)? onReverseListening,
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
    lastReverseAuthToken = reverseAuthToken;

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
  void cancel({String? reason}) {
    cancelCount++;
    super.cancel(reason: reason);
  }
}

class _FakeReceiverController extends ReceiverController {
  SecurityContext? lastTlsContext;
  Future<bool> Function(TransferAuthRequest request)? capturedAuthV2;
  Function(TransferModel)? capturedOnUpdate;
  void Function()? capturedOnDone;
  final List<Map<String, dynamic>> reverseCalls = [];

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
    int maxParallelStreams = 4,
  }) async {
    lastTlsContext = tlsContext;
    capturedOnUpdate = onUpdate;
    capturedAuthV2 = onRequestAuthV2;
    capturedOnDone = onDone;
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
    int maxParallelStreams = 4,
    void Function()? onDone,
  }) async {
    capturedOnUpdate = onUpdate;
    reverseCalls.add({
      'senderIp': senderIp,
      'port': port,
      'useTls': useTls,
      'expectedSenderFingerprint': expectedSenderFingerprint,
      'reverseAuthToken': reverseAuthToken,
    });
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

  TransferCubit buildCubit() {
    return TransferCubit(
      sender: fakeSender,
      receiver: fakeReceiver,
      discoveryService: discovery,
      identityService: identityService,
      trustedDevicesService: trustedService,
      directBridge: fakeBridge,
      peerRegistry: registry,
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
    expect(cubit.state.authRequest!.sasCode, isNotNull);

    cubit.resolveAuth(false);
    expect(await mismatchFuture, isFalse);
  });

  test('trustPeerFromQr and revokeTrustedDevice update trustedDevices & UnifiedPeers', () async {
    final cubit = buildCubit();
    addTearDown(cubit.close);
    await cubit.initializeFabric(deviceName: 'Laptop');

    final peerFp = List.filled(64, 'e').join();
    final uri = PairingQrCodec.encode(
      PairingToken(
        peerId: 'ffeeddccbbaa9988',
        name: 'Office Phone',
        fingerprint: peerFp,
        lanIp: '192.168.1.77',
        port: 62004,
        platform: PeerPlatform.android,
      ),
    );

    final paired = await cubit.trustPeerFromQr(uri);
    expect(paired, isNotNull);
    expect(cubit.state.trustedDevices.length, 1);
    expect(cubit.state.unifiedPeers.first.isTrusted, isTrue);
    expect(cubit.state.targetIp, '192.168.1.77');

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
}
