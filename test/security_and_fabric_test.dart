import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:daphq/fabric/ble_beacon_codec.dart';
import 'package:daphq/fabric/direct_native_bridge.dart';
import 'package:daphq/fabric/peer_models.dart';
import 'package:daphq/fabric/peer_registry.dart';
import 'package:daphq/fabric/smart_link_evaluator.dart';
import 'package:daphq/models/discovery_model.dart';
import 'package:daphq/security/device_identity_service.dart';
import 'package:daphq/security/trusted_devices_service.dart';
import 'package:daphq/services/discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDirA;
  late Directory tempDirB;

  setUp(() {
    tempDirA = Directory.systemTemp.createTempSync('daphq_id_a_');
    tempDirB = Directory.systemTemp.createTempSync('daphq_id_b_');
  });

  tearDown(() {
    if (tempDirA.existsSync()) tempDirA.deleteSync(recursive: true);
    if (tempDirB.existsSync()) tempDirB.deleteSync(recursive: true);
  });

  group('DeviceIdentityService (EC P-256 + TLS + SAS)', () {
    test('generates, persists, and reloads stable peerId and certFingerprint', () async {
      final serviceA = DeviceIdentityService(directoryProvider: () async => tempDirA);
      final id1 = await serviceA.loadOrCreate();
      expect(id1.peerId, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(id1.certFingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(id1.certificatePem, contains('BEGIN CERTIFICATE'));
      expect(id1.privateKeyPem, contains('PRIVATE KEY'));

      // Reload from disk via a fresh service instance
      final serviceA2 = DeviceIdentityService(directoryProvider: () async => tempDirA);
      final id2 = await serviceA2.loadOrCreate();
      expect(id2.peerId, id1.peerId);
      expect(id2.certFingerprint, id1.certFingerprint);

      // Independent device dir gets a distinct cryptographic identity
      final serviceB = DeviceIdentityService(directoryProvider: () async => tempDirB);
      final idB = await serviceB.loadOrCreate();
      expect(idB.peerId, isNot(id1.peerId));
      expect(idB.certFingerprint, isNot(id1.certFingerprint));
    });

    test('createServerContext binds real TLS SecureServerSocket and verifies cert DER SHA-256', () async {
      final service = DeviceIdentityService(directoryProvider: () async => tempDirA);
      final identity = await service.loadOrCreate();

      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        identity.createServerContext(),
      );

      final receivedFuture = server.first.then((socket) async {
        final msg = await utf8.decodeStream(socket);
        await socket.close();
        return msg;
      });

      String? observedFingerprint;
      final client = await SecureSocket.connect(
        InternetAddress.loopbackIPv4.address,
        server.port,
        onBadCertificate: (cert) {
          observedFingerprint = sha256.convert(cert.der).toString();
          return observedFingerprint == identity.certFingerprint;
        },
      );
      client.write('daphq-tls-ok');
      await client.flush();
      await client.close();

      expect(observedFingerprint, identity.certFingerprint);
      expect(await receivedFuture, 'daphq-tls-ok');
      await server.close();
    });

    test('computeSasCode is symmetric and order-independent', () {
      const fpA =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const fpB =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

      final sas1 = DeviceIdentityService.computeSasCode(fpA, fpB);
      final sas2 = DeviceIdentityService.computeSasCode(fpB, fpA);

      expect(sas1, matches(RegExp(r'^\d{4}$')));
      expect(sas1, sas2);
    });
  });

  group('TrustedDevicesService (Serialized Trust Store + MITM Mismatch)', () {
    test('concurrent trustDevice writes do not lose records and reload cleanly', () async {
      final service = TrustedDevicesService(directoryProvider: () async => tempDirA);
      await Future.wait([
        service.trustDevice(
          peerId: '1111111111111111',
          certFingerprint: 'aa' * 32,
          displayName: 'Pixel 9',
          platform: 'android',
        ),
        service.trustDevice(
          peerId: '2222222222222222',
          certFingerprint: 'bb' * 32,
          displayName: 'Workstation',
          platform: 'windows',
        ),
        service.trustDevice(
          peerId: '3333333333333333',
          certFingerprint: 'cc' * 32,
          displayName: 'Tablet Pro',
          platform: 'android',
        ),
      ]);

      final reloaded = TrustedDevicesService(directoryProvider: () async => tempDirA);
      final list = await reloaded.listTrustedDevices();
      expect(list.length, 3);
      expect(list.map((d) => d.peerId).toSet(), {
        '1111111111111111',
        '2222222222222222',
        '3333333333333333',
      });
    });

    test('checkTrust detects unknown, exact match, and fingerprintMismatch MITM', () async {
      final service = TrustedDevicesService(directoryProvider: () async => tempDirA);
      const peerId = 'abcdef0123456789';
      final fp = '0123456789abcdef' * 4;

      expect(await service.checkTrust(peerId, fp), TrustCheckResult.unknown);
      expect(await service.isTrusted(peerId, fp), isFalse);

      await service.trustDevice(
        peerId: peerId,
        certFingerprint: fp,
        displayName: 'Phone X',
        platform: 'android',
      );

      expect(
        await service.checkTrust(peerId, fp.toUpperCase()),
        TrustCheckResult.trusted,
      );
      expect(await service.isTrusted(peerId, fp), isTrue);

      final spoofedFp = 'ffffffffffffffff' * 4;
      expect(
        await service.checkTrust(peerId, spoofedFp),
        TrustCheckResult.fingerprintMismatch,
      );
      expect(await service.isTrusted(peerId, spoofedFp), isFalse);
    });

    test('revokeDevice removes peer and persists atomically', () async {
      final service = TrustedDevicesService(directoryProvider: () async => tempDirA);
      await service.trustDevice(
        peerId: 'aaaa1111bbbb2222',
        certFingerprint: '11' * 32,
        displayName: 'Studio PC',
        platform: 'windows',
      );
      expect((await service.listTrustedDevices()).length, 1);

      await service.revokeDevice('aaaa1111bbbb2222');

      final fresh = TrustedDevicesService(directoryProvider: () async => tempDirA);
      expect(await fresh.listTrustedDevices(), isEmpty);
      expect(
        await fresh.checkTrust('aaaa1111bbbb2222', '11' * 32),
        TrustCheckResult.unknown,
      );
    });
  });

  group('BleBeaconCodec, PairingQrCodec & PeerRegistry', () {
    test('BleBeaconCodec roundtrips 22-byte Manufacturer Payload and rejects malformed lengths', () {
      const original = BleBeaconPayload(
        caps: PeerCapabilities(
          tlsSupported: true,
          direct5gHostCapable: true,
          directClientCapable: true,
          multiStreamSupported: true,
          busy: false,
          platform: PeerPlatform.android,
        ),
        peerId: '0123456789abcdef',
        fingerprintPrefix: 'fedcba9876543210',
        transferPort: 62004,
        sessionNonce: 0xBEEF,
      );

      final bytes = BleBeaconCodec.encode(original);
      expect(bytes.length, BleBeaconCodec.payloadLength);
      expect(bytes.length, 22);

      final decoded = BleBeaconCodec.decode(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.peerId, original.peerId);
      expect(decoded.fingerprintPrefix, original.fingerprintPrefix);
      expect(decoded.transferPort, 62004);
      expect(decoded.sessionNonce, 0xBEEF);
      expect(decoded.caps.tlsSupported, isTrue);
      expect(decoded.caps.direct5gHostCapable, isTrue);
      expect(decoded.caps.multiStreamSupported, isTrue);
      expect(decoded.caps.platform, PeerPlatform.android);

      // Malformed packets rejected gracefully
      expect(BleBeaconCodec.decode(Uint8List(21)), isNull);
      expect(BleBeaconCodec.decode(Uint8List(23)), isNull);
      final badVersion = Uint8List.fromList(bytes)..[0] = 99;
      expect(BleBeaconCodec.decode(badVersion), isNull);
    });

    test('PairingQrCodec roundtrips daphq://pair URI with SoftAP credentials & rejects invalid input', () {
      final token = PairingToken(
        peerId: 'a1b2c3d4e5f60708',
        fingerprint: 'ab' * 32,
        name: 'Omar Pixel 9',
        platform: PeerPlatform.android,
        lanIp: '192.168.49.1',
        port: 62004,
        ssid: 'DIRECT-DQ-8821',
        psk: 'Tr0pic@lDirect99',
      );

      final uri = PairingQrCodec.encode(token);
      expect(uri, startsWith('daphq://pair?'));

      final parsed = PairingQrCodec.decode(uri);
      expect(parsed, isNotNull);
      expect(parsed!.peerId, token.peerId);
      expect(parsed.fingerprint, token.fingerprint);
      expect(parsed.name, token.name);
      expect(parsed.platform, PeerPlatform.android);
      expect(parsed.lanIp, '192.168.49.1');
      expect(parsed.port, 62004);
      expect(parsed.ssid, 'DIRECT-DQ-8821');
      expect(parsed.psk, 'Tr0pic@lDirect99');

      expect(PairingQrCodec.decode('https://example.com'), isNull);
      expect(PairingQrCodec.decode('daphq://pair?peerId=bad'), isNull);
    });

    test('PeerRegistry deduplicates same peerId across LAN & BLE and expires transports independently', () {
      final registry = PeerRegistry();
      final t0 = DateTime(2026, 11, 13, 12, 0, 0);

      // 1. Discovered on BLE first
      registry.upsertBleBeacon(
        const BleBeaconPayload(
          caps: PeerCapabilities(
            tlsSupported: true,
            direct5gHostCapable: true,
            directClientCapable: true,
            multiStreamSupported: true,
            platform: PeerPlatform.windows,
          ),
          peerId: '1122334455667788',
          fingerprintPrefix: '9988776655443322',
          transferPort: 62004,
          sessionNonce: 42,
        ),
        bleAddress: 'AA:BB:CC:DD:EE:FF',
        deviceName: 'WinStation',
        rssi: -52,
        now: t0,
      );

      expect(registry.currentPeers.length, 1);
      expect(registry.currentPeers.first.transportKind, PeerTransportKind.bleDirectOnly);
      expect(registry.currentPeers.first.name, 'WinStation');

      // 2. Same peerId arrives via LAN UDP 1s later -> merged into 1 peer
      final t1 = t0.add(const Duration(seconds: 1));
      final lanModel = DiscoveryModel.fromJson(<String, dynamic>{
        'name': 'WinStation Pro',
        'peerId': '1122334455667788',
        'fp': '9988776655443322${'00' * 24}',
        'port': 62004,
        'caps': const PeerCapabilities(
          tlsSupported: true,
          direct5gHostCapable: true,
          directClientCapable: true,
          multiStreamSupported: true,
          platform: PeerPlatform.windows,
        ).toFlagsByte(),
      }, '192.168.1.44');

      registry.upsertLanDiscovery(lanModel, now: t1);
      expect(registry.currentPeers.length, 1);

      final merged = registry.currentPeers.first;
      expect(merged.transportKind, PeerTransportKind.dualLanAndBle);
      expect(merged.lanIp, '192.168.1.44');
      expect(merged.bleAddress, 'AA:BB:CC:DD:EE:FF');
      expect(merged.name, 'WinStation Pro');
      expect(merged.certFingerprint, '9988776655443322${'00' * 24}');

      // 3. After LAN TTL expires (8s after t1) while BLE stays fresh (refreshed at t0+6s)
      final tRefreshBle = t0.add(const Duration(seconds: 6));
      registry.upsertBleBeacon(
        const BleBeaconPayload(
          caps: PeerCapabilities(
            tlsSupported: true,
            direct5gHostCapable: true,
            directClientCapable: true,
            multiStreamSupported: true,
            platform: PeerPlatform.windows,
          ),
          peerId: '1122334455667788',
          fingerprintPrefix: '9988776655443322',
          transferPort: 62004,
          sessionNonce: 43,
        ),
        bleAddress: 'AA:BB:CC:DD:EE:FF',
        rssi: -49,
        now: tRefreshBle,
      );

      registry.pruneExpired(
        lanTtl: const Duration(seconds: 7),
        bleTtl: const Duration(seconds: 10),
        now: t1.add(const Duration(seconds: 8)),
      );
      expect(registry.currentPeers.length, 1);
      expect(registry.currentPeers.first.lanIp, isNull);
      expect(registry.currentPeers.first.transportKind, PeerTransportKind.bleDirectOnly);

      // 4. After BLE TTL also expires -> removed completely
      registry.pruneExpired(
        lanTtl: const Duration(seconds: 7),
        bleTtl: const Duration(seconds: 10),
        now: tRefreshBle.add(const Duration(seconds: 11)),
      );
      expect(registry.currentPeers, isEmpty);
      registry.dispose();
    });
  });

  group('SmartLinkEvaluator & DirectNativeBridge', () {
    test('chooses LAN TLS v2 4-stream silently in autoSmart when healthy LAN exists', () {
      const evaluator = SmartLinkEvaluator();
      const localCaps = LocalRadioCapabilities(
        hasWifi: true,
        hasBle: true,
        canHostDirect5g: true,
        localPlatform: PeerPlatform.android,
      );
      const peer = UnifiedPeer(
        peerId: 'aaaa111122223333',
        name: 'Studio Win',
        platform: PeerPlatform.windows,
        lanIp: '192.168.1.25',
        bleAddress: '11:22:33:44:55:66',
        caps: PeerCapabilities(
          tlsSupported: true,
          direct5gHostCapable: true,
          directClientCapable: true,
          multiStreamSupported: true,
          platform: PeerPlatform.windows,
        ),
      );

      final plan = evaluator.planTransfer(
        peer: peer,
        preference: TransportPreference.autoSmart,
        localCaps: localCaps,
        localPeerId: 'bbbb111122223333',
      );

      expect(plan.strategy, LinkExecutionStrategy.lanTlsDirect);
      expect(plan.useTls, isTrue);
      expect(plan.parallelStreams, 4);
      expect(plan.useReverseConnect, isFalse);
    });

    test('escalates to BLE Direct P2P with Android GO & Windows Reverse-Connect when router is absent', () {
      const evaluator = SmartLinkEvaluator();
      const androidLocal = LocalRadioCapabilities(
        hasWifi: true,
        hasBle: true,
        canHostDirect5g: true,
        localPlatform: PeerPlatform.android,
      );
      const winPeer = UnifiedPeer(
        peerId: 'aaaa111122223333',
        name: 'Win Laptop',
        platform: PeerPlatform.windows,
        lanIp: null,
        bleAddress: '11:22:33:44:55:66',
        caps: PeerCapabilities(
          tlsSupported: true,
          direct5gHostCapable: true,
          directClientCapable: true,
          multiStreamSupported: true,
          platform: PeerPlatform.windows,
        ),
      );

      final plan = evaluator.planTransfer(
        peer: winPeer,
        preference: TransportPreference.autoSmart,
        localCaps: androidLocal,
        localPeerId: 'cccc111122223333',
      );

      expect(plan.strategy, LinkExecutionStrategy.bleTriggeredDirectP2p);
      expect(plan.useTls, isTrue);
      expect(plan.parallelStreams, 4);
      expect(plan.shouldLocalHostDirectGroup, isTrue);
      expect(plan.useReverseConnect, isTrue);
    });

    test('honors directTurbo preference even when LAN IP is available', () {
      const evaluator = SmartLinkEvaluator();
      const winLocal = LocalRadioCapabilities(
        hasWifi: true,
        hasBle: true,
        canHostDirect5g: true,
        localPlatform: PeerPlatform.windows,
      );
      const androidPeer = UnifiedPeer(
        peerId: '1111222233334444',
        name: 'Galaxy S25',
        platform: PeerPlatform.android,
        lanIp: '192.168.1.99',
        bleAddress: 'AA:BB:CC:DD:EE:11',
        caps: PeerCapabilities(
          tlsSupported: true,
          direct5gHostCapable: true,
          directClientCapable: true,
          multiStreamSupported: true,
          platform: PeerPlatform.android,
        ),
      );

      final plan = evaluator.planTransfer(
        peer: androidPeer,
        preference: TransportPreference.directTurbo,
        localCaps: winLocal,
        localPeerId: '2222333344445555',
      );

      expect(plan.strategy, LinkExecutionStrategy.bleTriggeredDirectP2p);
      expect(plan.shouldLocalHostDirectGroup, isFalse);
      expect(plan.useReverseConnect, isFalse);
      expect(plan.parallelStreams, 4);
    });

    test('falls back to QR manual pairing when peer has no LAN and local device lacks Wi-Fi or BLE', () {
      const evaluator = SmartLinkEvaluator();
      const desktopNoBle = LocalRadioCapabilities(
        hasWifi: false,
        hasBle: false,
        canHostDirect5g: false,
        localPlatform: PeerPlatform.windows,
      );
      const bleOnlyPeer = UnifiedPeer(
        peerId: 'deadbeef00001111',
        name: 'Phone',
        platform: PeerPlatform.android,
        bleAddress: '00:11:22:33:44:55',
        caps: PeerCapabilities(
          tlsSupported: true,
          direct5gHostCapable: true,
          directClientCapable: true,
          multiStreamSupported: true,
          platform: PeerPlatform.android,
        ),
      );

      final plan = evaluator.planTransfer(
        peer: bleOnlyPeer,
        preference: TransportPreference.autoSmart,
        localCaps: desktopNoBle,
        localPeerId: 'cafe000011112222',
      );

      expect(plan.strategy, LinkExecutionStrategy.manualQrFallback);
    });

    test('DirectNativeBridge parses native BLE beacon & GATT request events safely', () {
      final beaconBytes = BleBeaconCodec.encode(
        const BleBeaconPayload(
          caps: PeerCapabilities(
            tlsSupported: true,
            direct5gHostCapable: true,
            directClientCapable: true,
            multiStreamSupported: true,
            platform: PeerPlatform.android,
          ),
          peerId: '0011223344556677',
          fingerprintPrefix: '8899aabbccddeeff',
          transferPort: 62004,
          sessionNonce: 7,
        ),
      );

      final parsedBeacon = DirectNativeBridge.parseEvent(<String, dynamic>{
        'type': 'bleBeacon',
        'address': 'AA:11:22:33:44:55',
        'name': 'Pixel',
        'rssi': -48,
        'payload': beaconBytes,
      });

      expect(parsedBeacon, isA<DirectBleBeaconEvent>());
      final ev = parsedBeacon! as DirectBleBeaconEvent;
      expect(ev.bleAddress, 'AA:11:22:33:44:55');
      expect(ev.rssi, -48);
      expect(ev.decodedPayload?.peerId, '0011223344556677');

      final parsedGatt = DirectNativeBridge.parseEvent(<String, dynamic>{
        'type': 'gattLinkRequest',
        'requestId': 'req-1',
        'peerId': '0011223344556677',
        'peerName': 'Pixel',
        'action': 'connectClient',
        'ssid': 'DIRECT-DQ-1234',
        'psk': 'pass9988',
        'hostIp': '192.168.49.1',
        'port': 62004,
        'reverseConnect': true,
      });
      expect(parsedGatt, isA<DirectGattLinkRequestEvent>());
      final gatt = parsedGatt! as DirectGattLinkRequestEvent;
      expect(gatt.ssid, 'DIRECT-DQ-1234');
      expect(gatt.useReverseConnect, isTrue);
    });

    test('PeerRegistry.touchLanHeartbeat extends LAN TTL across repeated heartbeats', () {
      final registry = PeerRegistry();
      final t0 = DateTime(2026, 11, 13, 12, 0, 0);
      final lanModel = DiscoveryModel.fromJson(<String, dynamic>{
        'name': 'Desktop Host',
        'peerId': '1122334455667788',
        'fp': 'ab' * 32,
        'port': 62004,
      }, '192.168.1.40');

      registry.upsertLanDiscovery(lanModel, now: t0);
      // Heartbeat arrives 5s later with unchanged metadata
      registry.touchLanHeartbeat(lanModel, now: t0.add(const Duration(seconds: 5)));

      // At t0 + 9s (beyond 7s from t0, within 7s from t0+5s), peer MUST remain alive
      final pruned = registry.pruneExpired(
        lanTtl: const Duration(seconds: 7),
        now: t0.add(const Duration(seconds: 9)),
      );
      expect(pruned, isFalse);
      expect(registry.currentPeers.length, 1);
      expect(registry.currentPeers.first.hasLan, isTrue);
      registry.dispose();
    });

    test('DiscoveryService filters VPN/tunnel/virtual adapters while preserving Wi-Fi/Ethernet', () {
      for (final virt in [
        'Tailscale',
        'ZeroTier Virtual Port',
        'WireGuard Tunnel',
        'wg0',
        'Wintun Userspace Tunnel',
        'vEthernet (WSL)',
        'NordLynx',
        'ProtonVPN TUN',
        'Mullvad',
      ]) {
        expect(DiscoveryService.isVirtualInterfaceName(virt), isTrue, reason: virt);
      }

      for (final physical in ['Wi-Fi', 'Ethernet', 'wlan0', 'eth0', 'en0']) {
        expect(DiscoveryService.isVirtualInterfaceName(physical), isFalse, reason: physical);
      }
    });

    test('PeerRegistry.setTrustedPeers quarantines spoofed LAN/BLE peers without clobbering pinned peer', () {
      final reg = PeerRegistry();
      addTearDown(reg.dispose);

      const pinnedId = '0011223344556677';
      final pinnedFp = List.filled(64, 'a').join();
      final spoofFp = List.filled(64, 'f').join();
      reg.setTrustedPeers({pinnedId: pinnedFp});

      final legit = reg.upsertLanDiscovery(
        DiscoveryModel.fromJson(<String, dynamic>{
          'name': 'PinnedPhone',
          'peerId': pinnedId,
          'fp': pinnedFp,
          'port': 62004,
        }, '192.168.1.10'),
      );
      expect(legit.isTrusted, isTrue);
      expect(reg.getByPeerId(pinnedId)?.lanIp, '192.168.1.10');

      final spoofLan = reg.upsertLanDiscovery(
        DiscoveryModel.fromJson(<String, dynamic>{
          'name': 'PinnedPhone',
          'peerId': pinnedId,
          'fp': spoofFp,
          'port': 62004,
        }, '192.168.1.99'),
      );
      expect(spoofLan.isTrusted, isFalse);
      expect(spoofLan.peerId, 'unverified:192.168.1.99');
      expect(reg.getByPeerId(pinnedId)?.lanIp, '192.168.1.10');
      expect(reg.getByPeerId(pinnedId)?.certFingerprint, pinnedFp);
      expect(reg.getByPeerId(pinnedId)?.isTrusted, isTrue);

      final spoofBle = reg.upsertBleBeacon(
        BleBeaconPayload(
          peerId: pinnedId,
          fingerprintPrefix: spoofFp.substring(0, 16),
          transferPort: 62004,
          caps: const PeerCapabilities(platform: PeerPlatform.android),
        ),
        bleAddress: 'DE:AD:BE:EF:00:01',
        deviceName: 'PinnedPhone',
        rssi: -42,
      );
      expect(spoofBle.isTrusted, isFalse);
      expect(spoofBle.peerId, 'unverified_ble:de:ad:be:ef:00:01');
      expect(reg.getByPeerId(pinnedId)?.bleAddress, isNull);
    });

    test('DirectNativeBridge.parseEvent preserves reverseToken in gattLinkRequest', () {
      final parsed = DirectNativeBridge.parseEvent(<String, dynamic>{
        'type': 'gattLinkRequest',
        'requestId': 'req-tok-1',
        'peerId': '0011223344556677',
        'peerName': 'Pixel',
        'action': 'joinHost',
        'ssid': 'DIRECT-DQ-777',
        'psk': 'pass7777',
        'hostIp': '192.168.49.1',
        'port': 62004,
        'reverseConnect': true,
        'reverseToken': 'secret-rev-token-99',
      });
      expect(parsed, isA<DirectGattLinkRequestEvent>());
      final gatt = parsed! as DirectGattLinkRequestEvent;
      expect(gatt.reverseToken, 'secret-rev-token-99');
      expect(gatt.useReverseConnect, isTrue);
    });

    test('SmartLinkEvaluator aligns useReverseConnect with localHostsGo across Android and Windows', () {
      const evaluator = SmartLinkEvaluator();
      final winPeer = UnifiedPeer(
        peerId: 'win-peer-1',
        name: 'WinPC',
        platform: PeerPlatform.windows,
        bleAddress: 'AA:BB:CC:DD:EE:01',
        caps: const PeerCapabilities(
          direct5gHostCapable: false,
          directClientCapable: true,
          tlsSupported: true,
          multiStreamSupported: true,
          platform: PeerPlatform.windows,
        ),
        lastSeenBle: DateTime.now(),
      );
      final androidToWin = evaluator.planTransfer(
        peer: winPeer,
        preference: TransportPreference.directTurbo,
        localCaps: const LocalRadioCapabilities(
          hasWifi: true,
          hasBle: true,
          canHostDirect5g: false,
          localPlatform: PeerPlatform.android,
        ),
        localPeerId: 'zzzz-android-id',
      );
      expect(androidToWin.strategy, LinkExecutionStrategy.bleTriggeredDirectP2p);
      expect(androidToWin.shouldLocalHostDirectGroup, isTrue);
      expect(androidToWin.useReverseConnect, androidToWin.shouldLocalHostDirectGroup);

      final androidPeer = UnifiedPeer(
        peerId: '0000-android-id',
        name: 'Phone',
        platform: PeerPlatform.android,
        bleAddress: 'AA:BB:CC:DD:EE:02',
        caps: const PeerCapabilities(
          direct5gHostCapable: true,
          directClientCapable: true,
          tlsSupported: true,
          multiStreamSupported: true,
          platform: PeerPlatform.android,
        ),
        lastSeenBle: DateTime.now(),
      );
      final winToAndroid = evaluator.planTransfer(
        peer: androidPeer,
        preference: TransportPreference.directTurbo,
        localCaps: const LocalRadioCapabilities(
          hasWifi: true,
          hasBle: true,
          canHostDirect5g: true,
          localPlatform: PeerPlatform.windows,
        ),
        localPeerId: '0000-win-id',
      );
      expect(winToAndroid.strategy, LinkExecutionStrategy.bleTriggeredDirectP2p);
      expect(winToAndroid.shouldLocalHostDirectGroup, isFalse);
      expect(winToAndroid.useReverseConnect, isFalse);
    });
  });
}
