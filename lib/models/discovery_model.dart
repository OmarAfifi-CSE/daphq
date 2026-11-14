import '../fabric/peer_models.dart';

class DiscoveryModel {
  final String name;
  final String ip;
  final DateTime lastSeen;
  final String? peerId;
  final String? certFingerprint;
  final int port;
  final PeerCapabilities? caps;

  DiscoveryModel({
    required this.name,
    required this.ip,
    required this.lastSeen,
    this.peerId,
    this.certFingerprint,
    this.port = 62004,
    this.caps,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'ip': ip,
        if (peerId != null) 'peerId': peerId,
        if (certFingerprint != null) 'fp': certFingerprint,
        'port': port,
        if (caps != null) 'caps': caps!.toFlagsByte(),
      };

  factory DiscoveryModel.fromJson(Map<String, dynamic> json, String sourceIp) {
    final rawPeerId = json['peerId'] as String?;
    final rawFp = json['fp'] as String?;
    final rawCaps = json['caps'];
    return DiscoveryModel(
      name: (json['name'] as String?) ?? 'Unknown Device',
      ip: sourceIp,
      lastSeen: DateTime.now(),
      peerId: rawPeerId?.trim().isNotEmpty == true
          ? rawPeerId!.trim().toLowerCase()
          : null,
      certFingerprint:
          rawFp?.trim().isNotEmpty == true ? rawFp!.trim().toLowerCase() : null,
      port: (json['port'] as num?)?.toInt() ?? 62004,
      caps: rawCaps is num
          ? PeerCapabilities.fromFlagsByte(rawCaps.toInt())
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveryModel &&
          runtimeType == other.runtimeType &&
          ip == other.ip &&
          name == other.name &&
          peerId == other.peerId;

  @override
  int get hashCode => Object.hash(ip, name, peerId);
}
