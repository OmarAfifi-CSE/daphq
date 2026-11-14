import 'dart:async';

import '../models/discovery_model.dart';
import 'ble_beacon_codec.dart';
import 'peer_models.dart';

/// Deduplicating multi-plane registry that merges LAN UDP and BLE peers into [UnifiedPeer]s.
class PeerRegistry {
  final Map<String, UnifiedPeer> _peers = <String, UnifiedPeer>{};
  final Set<String> _trustedPeerIds = <String>{};
  final Map<String, String> _trustedFingerprints = <String, String>{};
  final StreamController<List<UnifiedPeer>> _controller =
      StreamController<List<UnifiedPeer>>.broadcast();

  Stream<List<UnifiedPeer>> get peersStream => _controller.stream;

  List<UnifiedPeer> get currentPeers {
    final list = _peers.values.toList(growable: false);
    list.sort((a, b) {
      if (a.isTrusted != b.isTrusted) {
        return a.isTrusted ? -1 : 1;
      }
      if (a.hasLan != b.hasLan) {
        return a.hasLan ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  void setTrustedPeerIds(Iterable<String> peerIds) {
    _trustedPeerIds
      ..clear()
      ..addAll(peerIds.map((id) => id.trim().toLowerCase()));
    _trustedFingerprints.clear();
    _recomputeTrustFlags();
  }

  void setTrustedPeers(Map<String, String> peerFingerprints) {
    _trustedPeerIds.clear();
    _trustedFingerprints.clear();
    for (final entry in peerFingerprints.entries) {
      final id = entry.key.trim().toLowerCase();
      final fp = entry.value.trim().toLowerCase();
      if (id.isEmpty) continue;
      _trustedPeerIds.add(id);
      if (fp.isNotEmpty) {
        _trustedFingerprints[id] = fp;
      }
    }
    _recomputeTrustFlags();
  }

  void _recomputeTrustFlags() {
    var changed = false;
    for (final entry in _peers.entries.toList()) {
      final trusted = _isPeerEntryTrusted(
        key: entry.key,
        certFingerprint: entry.value.certFingerprint,
        fingerprintPrefix: entry.value.fingerprintPrefix,
      );
      if (entry.value.isTrusted != trusted) {
        _peers[entry.key] = entry.value.copyWith(isTrusted: trusted);
        changed = true;
      }
    }
    if (changed) _emit();
  }

  bool _isPeerEntryTrusted({
    required String key,
    String? certFingerprint,
    String? fingerprintPrefix,
  }) {
    if (!_trustedPeerIds.contains(key)) return false;
    final pinnedFp = _trustedFingerprints[key];
    if (pinnedFp == null || pinnedFp.isEmpty) return true;
    final normCert = certFingerprint?.trim().toLowerCase();
    if (normCert != null && normCert.isNotEmpty) {
      return normCert == pinnedFp;
    }
    final normPrefix = fingerprintPrefix?.trim().toLowerCase();
    if (normPrefix != null && normPrefix.isNotEmpty) {
      return pinnedFp.startsWith(normPrefix);
    }
    return false;
  }

  UnifiedPeer upsertLanDiscovery(DiscoveryModel discovery, {DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final key = (discovery.peerId != null && discovery.peerId!.isNotEmpty)
        ? discovery.peerId!
        : 'legacy:${discovery.ip}';

    // Upgrade legacy IP entry if same IP now announces a v2 peerId.
    if (!key.startsWith('legacy:')) {
      _peers.remove('legacy:${discovery.ip}');
    }

    final existing = _peers[key];
    final caps = discovery.caps ?? existing?.caps ?? const PeerCapabilities();
    final platform = caps.platform != PeerPlatform.unknown
        ? caps.platform
        : (existing?.platform ?? PeerPlatform.unknown);
    final incomingFp = discovery.certFingerprint?.trim().toLowerCase();
    final pinnedFp = _trustedFingerprints[key];
    final existingFp = existing?.certFingerprint?.trim().toLowerCase();
    final bool fpMismatchTrusted = pinnedFp != null &&
        pinnedFp.isNotEmpty &&
        incomingFp != null &&
        incomingFp.isNotEmpty &&
        incomingFp != pinnedFp;
    final bool fpMismatchExisting = existingFp != null &&
        existingFp.isNotEmpty &&
        incomingFp != null &&
        incomingFp.isNotEmpty &&
        incomingFp != existingFp &&
        _trustedPeerIds.contains(key);

    if (fpMismatchTrusted || fpMismatchExisting) {
      final unverifiedKey = 'unverified:${discovery.ip}';
      final unverified = UnifiedPeer(
        peerId: unverifiedKey,
        name: '${discovery.name} (Unverified)',
        platform: platform,
        lanIp: discovery.ip,
        port: discovery.port,
        certFingerprint: incomingFp,
        fingerprintPrefix: incomingFp.length >= 16
            ? incomingFp.substring(0, 16)
            : null,
        caps: caps,
        isTrusted: false,
        lastSeenLan: timestamp,
      );
      _peers[unverifiedKey] = unverified;
      _emit();
      return unverified;
    }

    final certFp = (incomingFp != null && incomingFp.isNotEmpty)
        ? incomingFp
        : existing?.certFingerprint;
    final fpPrefix = certFp != null && certFp.length >= 16
        ? certFp.substring(0, 16)
        : existing?.fingerprintPrefix;
    final trusted = _isPeerEntryTrusted(
      key: key,
      certFingerprint: certFp,
      fingerprintPrefix: fpPrefix,
    );

    final updated = UnifiedPeer(
      peerId: key,
      name: discovery.name,
      platform: platform,
      lanIp: discovery.ip,
      port: discovery.port,
      certFingerprint: certFp,
      fingerprintPrefix: fpPrefix,
      bleAddress: existing?.bleAddress,
      rssi: existing?.rssi,
      caps: caps,
      isTrusted: trusted,
      lastSeenLan: timestamp,
      lastSeenBle: existing?.lastSeenBle,
    );

    _peers[key] = updated;
    _emit();
    return updated;
  }

  UnifiedPeer upsertBleBeacon(
    BleBeaconPayload beacon, {
    required String bleAddress,
    String? deviceName,
    int? rssi,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now();
    final key = beacon.peerId.trim().toLowerCase();
    final existing = _peers[key];

    final pinnedFp = _trustedFingerprints[key] ??
        existing?.certFingerprint?.trim().toLowerCase();
    final beaconPrefix = beacon.fingerprintPrefix.trim().toLowerCase();
    final bool hasPin = pinnedFp != null && pinnedFp.isNotEmpty;
    final bool prefixMismatch = hasPin &&
        (beaconPrefix.isEmpty || !pinnedFp.startsWith(beaconPrefix));

    if (prefixMismatch && (_trustedFingerprints.containsKey(key) || existing?.certFingerprint != null)) {
      final unverifiedKey = 'unverified_ble:${bleAddress.toLowerCase()}';
      final unverified = UnifiedPeer(
        peerId: unverifiedKey,
        name: (deviceName != null && deviceName.trim().isNotEmpty)
            ? '${deviceName.trim()} (Unverified)'
            : 'Unverified BLE Device',
        platform: beacon.caps.platform,
        port: beacon.transferPort,
        fingerprintPrefix: beacon.fingerprintPrefix,
        bleAddress: bleAddress,
        rssi: rssi,
        caps: beacon.caps,
        isTrusted: false,
        lastSeenBle: timestamp,
      );
      _peers[unverifiedKey] = unverified;
      _emit();
      return unverified;
    }

    final resolvedName = (existing != null &&
            existing.hasLan &&
            existing.name != 'Unknown Device')
        ? existing.name
        : ((deviceName != null && deviceName.trim().isNotEmpty)
            ? deviceName.trim()
            : (existing?.name ?? 'Nearby ${key.substring(0, 4).toUpperCase()}'));

    final trusted = _isPeerEntryTrusted(
      key: key,
      certFingerprint: existing?.certFingerprint,
      fingerprintPrefix: beacon.fingerprintPrefix,
    );

    final updated = UnifiedPeer(
      peerId: key,
      name: resolvedName,
      platform: beacon.caps.platform != PeerPlatform.unknown
          ? beacon.caps.platform
          : (existing?.platform ?? PeerPlatform.unknown),
      lanIp: existing?.lanIp,
      port: beacon.transferPort,
      certFingerprint: existing?.certFingerprint,
      fingerprintPrefix: beacon.fingerprintPrefix,
      bleAddress: bleAddress,
      rssi: rssi ?? existing?.rssi,
      caps: beacon.caps,
      isTrusted: trusted,
      lastSeenLan: existing?.lastSeenLan,
      lastSeenBle: timestamp,
    );

    _peers[key] = updated;
    _emit();
    return updated;
  }

  UnifiedPeer upsertQrToken(PairingToken token, {DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final key = token.peerId.trim().toLowerCase();
    final existing = _peers[key];

    final updated = UnifiedPeer(
      peerId: key,
      name: token.name,
      platform: token.platform != PeerPlatform.unknown
          ? token.platform
          : (existing?.platform ?? PeerPlatform.unknown),
      lanIp: token.lanIp ?? existing?.lanIp,
      port: token.port,
      certFingerprint: token.fingerprint,
      fingerprintPrefix: token.fingerprint.length >= 16
          ? token.fingerprint.substring(0, 16)
          : existing?.fingerprintPrefix,
      bleAddress: existing?.bleAddress,
      rssi: existing?.rssi,
      caps: (existing?.caps ?? const PeerCapabilities()).copyWith(
        tlsSupported: true,
        multiStreamSupported: true,
        platform: token.platform,
      ),
      isTrusted: _trustedPeerIds.contains(key),
      lastSeenLan: token.lanIp != null ? timestamp : existing?.lastSeenLan,
      lastSeenBle: existing?.lastSeenBle,
    );

    _peers[key] = updated;
    _emit();
    return updated;
  }

  /// Refreshes LAN heartbeat timestamp for an existing peer without emitting redundant UI events,
  /// or inserts the peer if not yet registered.
  void touchLanHeartbeat(DiscoveryModel discovery, {DateTime? now}) {
    final timestamp = now ?? DateTime.now();
    final key = (discovery.peerId != null && discovery.peerId!.isNotEmpty)
        ? discovery.peerId!
        : 'legacy:${discovery.ip}';
    final existing = _peers[key];
    if (existing == null) {
      upsertLanDiscovery(discovery, now: timestamp);
      return;
    }
    if (existing.lanIp != discovery.ip) {
      upsertLanDiscovery(discovery, now: timestamp);
      return;
    }
    _peers[key] = existing.copyWith(
      lastSeenLan: () => timestamp,
      port: discovery.port,
    );
  }

  UnifiedPeer? getByPeerId(String peerId) =>
      _peers[peerId.trim().toLowerCase()];

  UnifiedPeer? getByIp(String ip) {
    for (final p in _peers.values) {
      if (p.lanIp == ip) return p;
    }
    return null;
  }

  bool pruneExpired({
    Duration lanTtl = const Duration(seconds: 7),
    Duration bleTtl = const Duration(seconds: 10),
    DateTime? now,
  }) {
    final cutoffNow = now ?? DateTime.now();
    var changed = false;

    for (final key in _peers.keys.toList()) {
      final peer = _peers[key]!;
      final lanFresh = peer.lastSeenLan != null &&
          cutoffNow.difference(peer.lastSeenLan!) <= lanTtl;
      final bleFresh = peer.lastSeenBle != null &&
          cutoffNow.difference(peer.lastSeenBle!) <= bleTtl;

      if (!lanFresh && !bleFresh) {
        _peers.remove(key);
        changed = true;
        continue;
      }

      if ((peer.hasLan && !lanFresh) || (peer.hasBle && !bleFresh)) {
        _peers[key] = peer.copyWith(
          lanIp: lanFresh ? () => peer.lanIp : () => null,
          lastSeenLan: lanFresh ? () => peer.lastSeenLan : () => null,
          bleAddress: bleFresh ? () => peer.bleAddress : () => null,
          rssi: bleFresh ? () => peer.rssi : () => null,
          lastSeenBle: bleFresh ? () => peer.lastSeenBle : () => null,
        );
        changed = true;
      }
    }

    if (changed) _emit();
    return changed;
  }

  void removeByIp(String ip) {
    final before = _peers.length;
    _peers.removeWhere((_, p) => p.lanIp == ip);
    if (_peers.length != before) _emit();
  }

  /// Clears only the LAN reachability of peers matching [ip], keeping BLE discovery active.
  void detachLanIp(String ip) {
    var changed = false;
    for (final key in _peers.keys.toList()) {
      final peer = _peers[key]!;
      if (peer.lanIp != ip) continue;
      if (peer.hasBle) {
        _peers[key] = peer.copyWith(
          lanIp: () => null,
          lastSeenLan: () => null,
        );
      } else {
        _peers.remove(key);
      }
      changed = true;
    }
    if (changed) _emit();
  }

  void removeByPeerId(String peerId) {
    if (_peers.remove(peerId.trim().toLowerCase()) != null) {
      _emit();
    }
  }

  void clear() {
    if (_peers.isEmpty) return;
    _peers.clear();
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(currentPeers);
    }
  }

  void dispose() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
