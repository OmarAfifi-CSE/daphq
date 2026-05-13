class DiscoveryModel {
  final String name;
  final String ip;
  final DateTime lastSeen;

  DiscoveryModel({
    required this.name,
    required this.ip,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'ip': ip,
  };

  factory DiscoveryModel.fromJson(Map<String, dynamic> json, String sourceIp) {
    return DiscoveryModel(
      name: json['name'] ?? 'Unknown Device',
      ip: sourceIp,
      lastSeen: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveryModel &&
          runtimeType == other.runtimeType &&
          ip == other.ip;

  @override
  int get hashCode => ip.hashCode;
}
