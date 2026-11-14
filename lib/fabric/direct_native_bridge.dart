import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ble_beacon_codec.dart';
import 'peer_models.dart';
import 'smart_link_evaluator.dart';

sealed class DirectFabricEvent {
  const DirectFabricEvent();
}

@immutable
class DirectBleBeaconEvent extends DirectFabricEvent {
  final String bleAddress;
  final String? deviceName;
  final int rssi;
  final Uint8List payloadBytes;
  final BleBeaconPayload? decodedPayload;

  const DirectBleBeaconEvent({
    required this.bleAddress,
    this.deviceName,
    required this.rssi,
    required this.payloadBytes,
    required this.decodedPayload,
  });
}

@immutable
class DirectGattLinkRequestEvent extends DirectFabricEvent {
  final String requestId;
  final String peerId;
  final String peerName;
  final String? peerFingerprint;
  final String action; // 'startDirectHost' | 'connectClient' | 'reverseReady' | 'teardown'
  final String? ssid;
  final String? psk;
  final String? hostIp;
  final int port;
  final bool useReverseConnect;
  final int? frequencyMhz;
  final String? sourceBleAddress;
  final String? reverseToken;

  const DirectGattLinkRequestEvent({
    required this.requestId,
    required this.peerId,
    required this.peerName,
    this.peerFingerprint,
    required this.action,
    this.ssid,
    this.psk,
    this.hostIp,
    this.port = 62004,
    this.useReverseConnect = false,
    this.frequencyMhz,
    this.sourceBleAddress,
    this.reverseToken,
  });
}

@immutable
class DirectP2pStateEvent extends DirectFabricEvent {
  final String state; // 'hostReady' | 'connected' | 'disconnected' | 'failed'
  final String? ssid;
  final String? psk;
  final String? localIp;
  final String? gatewayIp;
  final String? error;

  const DirectP2pStateEvent({
    required this.state,
    this.ssid,
    this.psk,
    this.localIp,
    this.gatewayIp,
    this.error,
  });
}

@immutable
class DirectRadioStateEvent extends DirectFabricEvent {
  final bool hasWifi;
  final bool hasBle;
  final bool bleAdvertising;
  final bool bleScanning;
  final bool canHostDirect5g;

  const DirectRadioStateEvent({
    required this.hasWifi,
    required this.hasBle,
    required this.bleAdvertising,
    required this.bleScanning,
    required this.canHostDirect5g,
  });
}

@immutable
class DirectHostInfo {
  final String ssid;
  final String psk;
  final String hostIp;
  final int frequencyMhz;

  const DirectHostInfo({
    required this.ssid,
    required this.psk,
    required this.hostIp,
    required this.frequencyMhz,
  });
}

@immutable
class DirectClientConnection {
  final String localIp;
  final String gatewayIp;

  const DirectClientConnection({
    required this.localIp,
    required this.gatewayIp,
  });
}

/// Unified Flutter <-> Native bridge (`com.omarafifi.daphq/direct_fabric`) driving
/// BLE discovery/GATT negotiation and OS Direct 5GHz Wi-Fi P2P across Android & Windows.
class DirectNativeBridge {
  static const String methodChannelName = 'com.omarafifi.daphq/direct_fabric';
  static const String eventChannelName =
      'com.omarafifi.daphq/direct_fabric/events';

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<DirectFabricEvent>? _cachedEvents;

  DirectNativeBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(methodChannelName),
        _eventChannel = eventChannel ?? const EventChannel(eventChannelName);

  static PeerPlatform currentPlatform() {
    if (Platform.isAndroid) return PeerPlatform.android;
    if (Platform.isWindows) return PeerPlatform.windows;
    return PeerPlatform.unknown;
  }

  Stream<DirectFabricEvent> get events {
    _cachedEvents ??= _eventChannel
        .receiveBroadcastStream()
        .handleError((_) {})
        .map((raw) {
          if (raw is Map) {
            return parseEvent(Map<String, dynamic>.from(raw));
          }
          return null;
        })
        .where((ev) => ev != null)
        .cast<DirectFabricEvent>();
    return _cachedEvents!;
  }

  static DirectFabricEvent? parseEvent(Map<String, dynamic> map) {
    final type = map['type'] as String?;
    switch (type) {
      case 'bleBeacon':
        final address = map['address'] as String? ?? '';
        if (address.isEmpty) return null;
        final rawPayload = map['payload'];
        Uint8List payloadBytes;
        if (rawPayload is Uint8List) {
          payloadBytes = rawPayload;
        } else if (rawPayload is List) {
          payloadBytes = Uint8List.fromList(
            rawPayload.map((e) => (e as num).toInt() & 0xFF).toList(),
          );
        } else {
          return null;
        }
        return DirectBleBeaconEvent(
          bleAddress: address,
          deviceName: map['name'] as String?,
          rssi: (map['rssi'] as num?)?.toInt() ?? -99,
          payloadBytes: payloadBytes,
          decodedPayload: BleBeaconCodec.decode(payloadBytes),
        );

      case 'gattLinkRequest':
        return DirectGattLinkRequestEvent(
          requestId: map['requestId'] as String? ?? '',
          peerId: map['peerId'] as String? ?? '',
          peerName: map['peerName'] as String? ?? 'Unknown Device',
          peerFingerprint: map['peerFingerprint'] as String?,
          action: map['action'] as String? ?? '',
          ssid: map['ssid'] as String?,
          psk: map['psk'] as String?,
          hostIp: map['hostIp'] as String?,
          port: (map['port'] as num?)?.toInt() ?? 62004,
          useReverseConnect: map['reverseConnect'] == true,
          frequencyMhz: (map['frequencyMhz'] as num?)?.toInt(),
          sourceBleAddress: map['sourceBleAddress'] as String?,
          reverseToken: map['reverseToken'] as String?,
        );

      case 'p2pState':
        return DirectP2pStateEvent(
          state: map['state'] as String? ?? 'disconnected',
          ssid: map['ssid'] as String?,
          psk: map['psk'] as String?,
          localIp: map['localIp'] as String?,
          gatewayIp: map['gatewayIp'] as String?,
          error: map['error'] as String?,
        );

      case 'radioState':
        return DirectRadioStateEvent(
          hasWifi: map['hasWifi'] == true,
          hasBle: map['hasBle'] == true,
          bleAdvertising: map['bleAdvertising'] == true,
          bleScanning: map['bleScanning'] == true,
          canHostDirect5g: map['canHostDirect5g'] == true,
        );

      default:
        return null;
    }
  }

  Future<LocalRadioCapabilities> getCapabilities() async {
    try {
      final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      if (raw == null) {
        return LocalRadioCapabilities.fallbackForPlatform(currentPlatform());
      }
      return LocalRadioCapabilities(
        hasWifi: raw['hasWifi'] == true,
        hasBle: raw['hasBle'] == true,
        canHostDirect5g: raw['canHostDirect5g'] == true,
        localPlatform: currentPlatform(),
      );
    } on MissingPluginException {
      return LocalRadioCapabilities.fallbackForPlatform(currentPlatform());
    } catch (_) {
      return LocalRadioCapabilities.fallbackForPlatform(currentPlatform());
    }
  }

  Future<bool> startBleDiscovery({
    required Uint8List beaconPayload,
    required String peerId,
    required String peerName,
    required String fingerprint,
  }) async {
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'startBleDiscovery',
        <String, dynamic>{
          'manufacturerId': BleBeaconCodec.manufacturerId,
          'beaconPayload': beaconPayload,
          'peerId': peerId,
          'peerName': peerName,
          'fingerprint': fingerprint,
        },
      );
      return result == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopBleDiscovery() async {
    try {
      await _methodChannel.invokeMethod<void>('stopBleDiscovery');
    } catch (_) {}
  }

  Future<DirectHostInfo?> startDirectHost({bool prefer5Ghz = true}) async {
    try {
      final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
        'startDirectHost',
        <String, dynamic>{'prefer5Ghz': prefer5Ghz},
      );
      if (raw == null || raw['ssid'] == null || raw['psk'] == null) {
        return null;
      }
      return DirectHostInfo(
        ssid: raw['ssid'] as String,
        psk: raw['psk'] as String,
        hostIp: raw['hostIp'] as String? ?? '192.168.49.1',
        frequencyMhz: (raw['frequencyMhz'] as num?)?.toInt() ?? 5180,
      );
    } catch (_) {
      return null;
    }
  }

  Future<DirectClientConnection?> connectDirectClient({
    required String ssid,
    required String psk,
    int? frequencyMhz,
    String? expectedGatewayIp,
  }) async {
    try {
      final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
        'connectDirectClient',
        <String, dynamic>{
          'ssid': ssid,
          'psk': psk,
          'frequencyMhz': ?frequencyMhz,
          'expectedGatewayIp': ?expectedGatewayIp,
        },
      );
      if (raw == null || raw['gatewayIp'] == null) {
        return null;
      }
      return DirectClientConnection(
        localIp: raw['localIp'] as String? ?? '',
        gatewayIp: raw['gatewayIp'] as String,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> exchangeGattLink({
    required String bleAddress,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final raw = await _methodChannel.invokeMapMethod<String, dynamic>(
        'exchangeGattLink',
        <String, dynamic>{
          'bleAddress': bleAddress,
          'payload': payload,
        },
      );
      return raw;
    } catch (_) {
      return null;
    }
  }

  Future<void> stopDirectSession() async {
    try {
      await _methodChannel.invokeMethod<void>('stopDirectSession');
    } catch (_) {}
  }
}
