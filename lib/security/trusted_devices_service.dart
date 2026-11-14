import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Result of checking a peer's TLS certificate fingerprint against the local trust store.
enum TrustCheckResult {
  trusted,
  unknown,
  fingerprintMismatch,
}

@immutable
class TrustedDevice {
  final String peerId;
  final String certFingerprint;
  final String displayName;
  final String platform;
  final int trustedAt;
  final int lastSeen;

  const TrustedDevice({
    required this.peerId,
    required this.certFingerprint,
    required this.displayName,
    required this.platform,
    required this.trustedAt,
    required this.lastSeen,
  });

  TrustedDevice copyWith({
    String? peerId,
    String? certFingerprint,
    String? displayName,
    String? platform,
    int? trustedAt,
    int? lastSeen,
  }) {
    return TrustedDevice(
      peerId: peerId ?? this.peerId,
      certFingerprint: certFingerprint ?? this.certFingerprint,
      displayName: displayName ?? this.displayName,
      platform: platform ?? this.platform,
      trustedAt: trustedAt ?? this.trustedAt,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'peerId': peerId,
        'certFingerprint': certFingerprint,
        'displayName': displayName,
        'platform': platform,
        'trustedAt': trustedAt,
        'lastSeen': lastSeen,
      };

  factory TrustedDevice.fromJson(Map<String, dynamic> json) {
    return TrustedDevice(
      peerId: (json['peerId'] as String? ?? '').trim().toLowerCase(),
      certFingerprint:
          (json['certFingerprint'] as String? ?? '').trim().toLowerCase(),
      displayName: json['displayName'] as String? ?? 'Unknown Device',
      platform: json['platform'] as String? ?? 'unknown',
      trustedAt: (json['trustedAt'] as num?)?.toInt() ?? 0,
      lastSeen: (json['lastSeen'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrustedDevice &&
          runtimeType == other.runtimeType &&
          peerId == other.peerId &&
          certFingerprint == other.certFingerprint &&
          displayName == other.displayName &&
          platform == other.platform &&
          trustedAt == other.trustedAt &&
          lastSeen == other.lastSeen;

  @override
  int get hashCode => Object.hash(
        peerId,
        certFingerprint,
        displayName,
        platform,
        trustedAt,
        lastSeen,
      );
}

/// Serialized atomic persistence store for trusted Daphq peers with MITM key-mismatch detection.
class TrustedDevicesService {
  static const String _storeFileName = 'daphq_trusted_devices.json';

  final Future<Directory> Function() _directoryProvider;
  Future<void> _writeQueue = Future<void>.value();

  TrustedDevicesService({Future<Directory> Function()? directoryProvider})
      : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory;

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<File> _getFile() async {
    final dir = await _directoryProvider();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}${Platform.pathSeparator}$_storeFileName');
  }

  Future<List<TrustedDevice>> _readUnlocked() async {
    final file = await _getFile();
    if (!await file.exists()) {
      return const <TrustedDevice>[];
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const <TrustedDevice>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <TrustedDevice>[];
    }
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(TrustedDevice.fromJson)
        .where((d) => d.peerId.isNotEmpty && d.certFingerprint.isNotEmpty)
        .toList();
  }

  Future<void> _writeUnlocked(List<TrustedDevice> devices) async {
    final file = await _getFile();
    final tmp = File('${file.path}.tmp');
    final encoded = jsonEncode(devices.map((d) => d.toJson()).toList());
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  Future<List<TrustedDevice>> listTrustedDevices() {
    return _enqueue(() async {
      final list = await _readUnlocked();
      list.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
      return list;
    });
  }

  Future<TrustedDevice?> getDevice(String peerId) {
    final normalizedId = peerId.trim().toLowerCase();
    return _enqueue(() async {
      final list = await _readUnlocked();
      for (final d in list) {
        if (d.peerId == normalizedId) {
          return d;
        }
      }
      return null;
    });
  }

  Future<TrustCheckResult> checkTrust(
    String peerId,
    String certFingerprint,
  ) {
    final normalizedId = peerId.trim().toLowerCase();
    final normalizedFp = certFingerprint.trim().toLowerCase();
    return _enqueue(() async {
      if (normalizedId.isEmpty || normalizedFp.isEmpty) {
        return TrustCheckResult.unknown;
      }
      final list = await _readUnlocked();
      for (final d in list) {
        if (d.peerId == normalizedId) {
          return d.certFingerprint == normalizedFp
              ? TrustCheckResult.trusted
              : TrustCheckResult.fingerprintMismatch;
        }
      }
      return TrustCheckResult.unknown;
    });
  }

  Future<bool> isTrusted(String peerId, String certFingerprint) async {
    return (await checkTrust(peerId, certFingerprint)) ==
        TrustCheckResult.trusted;
  }

  Future<TrustedDevice> trustDevice({
    required String peerId,
    required String certFingerprint,
    required String displayName,
    required String platform,
  }) {
    final normalizedId = peerId.trim().toLowerCase();
    final normalizedFp = certFingerprint.trim().toLowerCase();
    if (normalizedId.isEmpty || normalizedFp.isEmpty) {
      throw ArgumentError('peerId and certFingerprint must not be empty');
    }

    return _enqueue(() async {
      final list = await _readUnlocked();
      final now = DateTime.now().millisecondsSinceEpoch;
      final existingIdx = list.indexWhere((d) => d.peerId == normalizedId);
      final record = TrustedDevice(
        peerId: normalizedId,
        certFingerprint: normalizedFp,
        displayName:
            displayName.trim().isEmpty ? 'Unknown Device' : displayName.trim(),
        platform: platform.trim().isEmpty ? 'unknown' : platform.trim(),
        trustedAt: existingIdx >= 0 ? list[existingIdx].trustedAt : now,
        lastSeen: now,
      );
      final updated = List<TrustedDevice>.from(list);
      if (existingIdx >= 0) {
        updated[existingIdx] = record;
      } else {
        updated.add(record);
      }
      await _writeUnlocked(updated);
      return record;
    });
  }

  Future<void> touchLastSeen(String peerId, {String? displayName}) {
    final normalizedId = peerId.trim().toLowerCase();
    return _enqueue(() async {
      final list = await _readUnlocked();
      final idx = list.indexWhere((d) => d.peerId == normalizedId);
      if (idx < 0) return;
      final updated = List<TrustedDevice>.from(list);
      updated[idx] = updated[idx].copyWith(
        lastSeen: DateTime.now().millisecondsSinceEpoch,
        displayName: (displayName != null && displayName.trim().isNotEmpty)
            ? displayName.trim()
            : updated[idx].displayName,
      );
      await _writeUnlocked(updated);
    });
  }

  Future<void> revokeDevice(String peerId) {
    final normalizedId = peerId.trim().toLowerCase();
    return _enqueue(() async {
      final list = await _readUnlocked();
      final updated =
          list.where((d) => d.peerId != normalizedId).toList(growable: false);
      if (updated.length != list.length) {
        await _writeUnlocked(updated);
      }
    });
  }

  Future<void> clearAll() {
    return _enqueue(() async {
      await _writeUnlocked(const <TrustedDevice>[]);
    });
  }
}
