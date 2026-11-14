import 'package:flutter/foundation.dart';

import 'peer_models.dart';

@immutable
class BleBeaconPayload {
  final PeerCapabilities caps;
  final String peerId; // 16 hex chars (8 bytes)
  final String fingerprintPrefix; // 16 hex chars (8 bytes)
  final int transferPort;
  final int sessionNonce;

  const BleBeaconPayload({
    required this.caps,
    required this.peerId,
    required this.fingerprintPrefix,
    this.transferPort = 62004,
    this.sessionNonce = 0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BleBeaconPayload &&
          runtimeType == other.runtimeType &&
          caps == other.caps &&
          peerId == other.peerId &&
          fingerprintPrefix == other.fingerprintPrefix &&
          transferPort == other.transferPort &&
          sessionNonce == other.sessionNonce;

  @override
  int get hashCode => Object.hash(
        caps,
        peerId,
        fingerprintPrefix,
        transferPort,
        sessionNonce,
      );
}

/// Binary 22-byte BLE Manufacturer Data codec (`companyId = 0x4451` `'DQ'`).
///
/// Wire layout (22 bytes, network big-endian):
/// `[0] version (1B = 2)`
/// `[1] capabilityFlags (1B)`
/// `[2..9] peerId (8B)`
/// `[10..17] fingerprintPrefix (8B)`
/// `[18..19] transferPort (2B uint16)`
/// `[20..21] sessionNonce (2B uint16)`
class BleBeaconCodec {
  static const int manufacturerId = 0x4451; // ASCII 'DQ'
  static const int payloadVersion = 2;
  static const int payloadLength = 22;

  static final RegExp _hex16 = RegExp(r'^[0-9a-f]{16}$');

  static Uint8List encode(BleBeaconPayload payload) {
    final id = payload.peerId.trim().toLowerCase();
    final fpPrefix = payload.fingerprintPrefix.trim().toLowerCase();
    if (!_hex16.hasMatch(id)) {
      throw ArgumentError.value(payload.peerId, 'peerId', 'Must be 16 hex chars');
    }
    if (!_hex16.hasMatch(fpPrefix)) {
      throw ArgumentError.value(
        payload.fingerprintPrefix,
        'fingerprintPrefix',
        'Must be 16 hex chars',
      );
    }
    if (payload.transferPort <= 0 || payload.transferPort > 65535) {
      throw ArgumentError.value(
        payload.transferPort,
        'transferPort',
        'Must be between 1 and 65535',
      );
    }

    final bytes = Uint8List(payloadLength);
    final data = ByteData.sublistView(bytes);
    bytes[0] = payloadVersion;
    bytes[1] = payload.caps.toFlagsByte();
    _writeHexBytes(bytes, 2, id, 8);
    _writeHexBytes(bytes, 10, fpPrefix, 8);
    data.setUint16(18, payload.transferPort, Endian.big);
    data.setUint16(20, payload.sessionNonce & 0xFFFF, Endian.big);
    return bytes;
  }

  static BleBeaconPayload? decode(Uint8List bytes) {
    if (bytes.length != payloadLength) return null;
    if (bytes[0] != payloadVersion) return null;

    final data = ByteData.sublistView(bytes);
    final port = data.getUint16(18, Endian.big);
    if (port == 0) return null;

    final caps = PeerCapabilities.fromFlagsByte(bytes[1]);
    final peerId = _readHexBytes(bytes, 2, 8);
    final fpPrefix = _readHexBytes(bytes, 10, 8);
    final nonce = data.getUint16(20, Endian.big);

    return BleBeaconPayload(
      caps: caps,
      peerId: peerId,
      fingerprintPrefix: fpPrefix,
      transferPort: port,
      sessionNonce: nonce,
    );
  }

  static void _writeHexBytes(
    Uint8List out,
    int offset,
    String hex,
    int byteCount,
  ) {
    for (var i = 0; i < byteCount; i++) {
      out[offset + i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
  }

  static String _readHexBytes(Uint8List input, int offset, int byteCount) {
    final buf = StringBuffer();
    for (var i = 0; i < byteCount; i++) {
      buf.write(input[offset + i].toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
