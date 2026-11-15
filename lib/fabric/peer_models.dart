import 'package:flutter/foundation.dart';

import '../models/discovery_model.dart';

enum PeerPlatform {
  unknown,
  android,
  windows,
}

enum PeerTransportKind {
  lanOnly,
  bleDirectOnly,
  dualLanAndBle,
}

@immutable
class PeerCapabilities {
  static const int flagTlsSupported = 0x01;
  static const int flagDirect5gHost = 0x02;
  static const int flagDirectClient = 0x04;
  static const int flagMultiStream = 0x08;
  static const int flagBusy = 0x10;

  final bool tlsSupported;
  final bool direct5gHostCapable;
  final bool directClientCapable;
  final bool multiStreamSupported;
  final bool busy;
  final PeerPlatform platform;

  const PeerCapabilities({
    this.tlsSupported = false,
    this.direct5gHostCapable = false,
    this.directClientCapable = false,
    this.multiStreamSupported = false,
    this.busy = false,
    this.platform = PeerPlatform.unknown,
  });

  int toFlagsByte() {
    var value = 0;
    if (tlsSupported) value |= flagTlsSupported;
    if (direct5gHostCapable) value |= flagDirect5gHost;
    if (directClientCapable) value |= flagDirectClient;
    if (multiStreamSupported) value |= flagMultiStream;
    if (busy) value |= flagBusy;
    final platformBits = switch (platform) {
      PeerPlatform.unknown => 0,
      PeerPlatform.android => 1,
      PeerPlatform.windows => 2,
    };
    value |= (platformBits & 0x03) << 5;
    return value & 0xFF;
  }

  factory PeerCapabilities.fromFlagsByte(int raw) {
    final platformBits = (raw >> 5) & 0x03;
    final platform = switch (platformBits) {
      1 => PeerPlatform.android,
      2 => PeerPlatform.windows,
      _ => PeerPlatform.unknown,
    };
    return PeerCapabilities(
      tlsSupported: (raw & flagTlsSupported) != 0,
      direct5gHostCapable: (raw & flagDirect5gHost) != 0,
      directClientCapable: (raw & flagDirectClient) != 0,
      multiStreamSupported: (raw & flagMultiStream) != 0,
      busy: (raw & flagBusy) != 0,
      platform: platform,
    );
  }

  PeerCapabilities copyWith({
    bool? tlsSupported,
    bool? direct5gHostCapable,
    bool? directClientCapable,
    bool? multiStreamSupported,
    bool? busy,
    PeerPlatform? platform,
  }) {
    return PeerCapabilities(
      tlsSupported: tlsSupported ?? this.tlsSupported,
      direct5gHostCapable: direct5gHostCapable ?? this.direct5gHostCapable,
      directClientCapable: directClientCapable ?? this.directClientCapable,
      multiStreamSupported: multiStreamSupported ?? this.multiStreamSupported,
      busy: busy ?? this.busy,
      platform: platform ?? this.platform,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerCapabilities &&
          runtimeType == other.runtimeType &&
          tlsSupported == other.tlsSupported &&
          direct5gHostCapable == other.direct5gHostCapable &&
          directClientCapable == other.directClientCapable &&
          multiStreamSupported == other.multiStreamSupported &&
          busy == other.busy &&
          platform == other.platform;

  @override
  int get hashCode => Object.hash(
        tlsSupported,
        direct5gHostCapable,
        directClientCapable,
        multiStreamSupported,
        busy,
        platform,
      );
}

@immutable
class UnifiedPeer {
  final String peerId;
  final String name;
  final PeerPlatform platform;
  final String? lanIp;
  final int port;
  final String? certFingerprint;
  final String? fingerprintPrefix;
  final String? bleAddress;
  final int? rssi;
  final PeerCapabilities caps;
  final bool isTrusted;
  final DateTime? lastSeenLan;
  final DateTime? lastSeenBle;

  const UnifiedPeer({
    required this.peerId,
    required this.name,
    required this.platform,
    this.lanIp,
    this.port = 62004,
    this.certFingerprint,
    this.fingerprintPrefix,
    this.bleAddress,
    this.rssi,
    this.caps = const PeerCapabilities(),
    this.isTrusted = false,
    this.lastSeenLan,
    this.lastSeenBle,
  });

  bool get hasLan => lanIp != null && lanIp!.isNotEmpty;
  bool get hasBle => bleAddress != null && bleAddress!.isNotEmpty;
  bool get isLegacyV1 => peerId.startsWith('legacy:');
  bool get supportsDirect =>
      caps.direct5gHostCapable || caps.directClientCapable;

  PeerTransportKind get transportKind {
    if (hasLan && hasBle) return PeerTransportKind.dualLanAndBle;
    if (hasBle) return PeerTransportKind.bleDirectOnly;
    return PeerTransportKind.lanOnly;
  }

  String get displayTarget => lanIp ?? bleAddress ?? peerId;

  DiscoveryModel toDiscoveryModel() {
    return DiscoveryModel(
      name: name,
      ip: lanIp ?? 'ble:${bleAddress ?? peerId}',
      lastSeen: lastSeenLan ?? lastSeenBle ?? DateTime.now(),
      peerId: isLegacyV1 ? null : peerId,
      certFingerprint: certFingerprint,
      port: port,
      caps: caps,
    );
  }

  UnifiedPeer copyWith({
    String? peerId,
    String? name,
    PeerPlatform? platform,
    String? Function()? lanIp,
    int? port,
    String? Function()? certFingerprint,
    String? Function()? fingerprintPrefix,
    String? Function()? bleAddress,
    int? Function()? rssi,
    PeerCapabilities? caps,
    bool? isTrusted,
    DateTime? Function()? lastSeenLan,
    DateTime? Function()? lastSeenBle,
  }) {
    return UnifiedPeer(
      peerId: peerId ?? this.peerId,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      lanIp: lanIp != null ? lanIp() : this.lanIp,
      port: port ?? this.port,
      certFingerprint:
          certFingerprint != null ? certFingerprint() : this.certFingerprint,
      fingerprintPrefix: fingerprintPrefix != null
          ? fingerprintPrefix()
          : this.fingerprintPrefix,
      bleAddress: bleAddress != null ? bleAddress() : this.bleAddress,
      rssi: rssi != null ? rssi() : this.rssi,
      caps: caps ?? this.caps,
      isTrusted: isTrusted ?? this.isTrusted,
      lastSeenLan: lastSeenLan != null ? lastSeenLan() : this.lastSeenLan,
      lastSeenBle: lastSeenBle != null ? lastSeenBle() : this.lastSeenBle,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnifiedPeer &&
          runtimeType == other.runtimeType &&
          peerId == other.peerId &&
          name == other.name &&
          platform == other.platform &&
          lanIp == other.lanIp &&
          port == other.port &&
          certFingerprint == other.certFingerprint &&
          fingerprintPrefix == other.fingerprintPrefix &&
          bleAddress == other.bleAddress &&
          rssi == other.rssi &&
          caps == other.caps &&
          isTrusted == other.isTrusted;

  @override
  int get hashCode => Object.hash(
        peerId,
        name,
        platform,
        lanIp,
        port,
        certFingerprint,
        fingerprintPrefix,
        bleAddress,
        rssi,
        caps,
        isTrusted,
      );
}
