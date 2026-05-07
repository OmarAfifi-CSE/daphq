import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/discovery_model.dart';
import '../core/app_constants.dart';

class DiscoveryService {
  RawDatagramSocket? _socket;

  final StreamController<List<DiscoveryModel>> _devicesController =
      StreamController<List<DiscoveryModel>>.broadcast();

  final Map<String, DiscoveryModel> _discoveredDevices = {};

  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _reopenTimer;
  StreamSubscription? _connectivitySubscription;

  Set<String> _localIps = {};
  String? _lastDeviceName;
  bool isDiscoverable = true;
  bool _running = false;
  bool _isReopening = false;

  Stream<List<DiscoveryModel>> get devicesStream => _devicesController.stream;

  // ── Public API ─────────────────────────────────────────

  Future<void> startDiscovery(String deviceName) async {
    if (_running) return;
    _running = true;
    _lastDeviceName = deviceName;

    await _updateLocalIps();
    await _openSocket(deviceName);

    _broadcastTimer = Timer.periodic(
      const Duration(seconds: AppConstants.discoveryIntervalSeconds),
      (_) {
        if (_running && isDiscoverable) {
          _broadcastPresence(deviceName, isOnline: true);
        }
      },
    );

    _cleanupTimer = Timer.periodic(
      const Duration(seconds: AppConstants.discoveryIntervalSeconds),
      (_) => _cleanupDevices(),
    );

    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((results) => _onConnectivityChanged(results, deviceName));
  }

  void triggerBroadcast({bool isOnline = true}) {
    isDiscoverable = isOnline;
    if (_lastDeviceName != null) {
      _broadcastPresence(_lastDeviceName!, isOnline: isOnline);
    }
  }

  Future<void> stop() async {
    _running = false;
    _reopenTimer?.cancel();
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    await _connectivitySubscription?.cancel();
    _reopenTimer = _broadcastTimer = _cleanupTimer = null;
    _connectivitySubscription = null;
    _safeCloseSocket();
  }

  // ── Network Change ─────────────────────────────────────

  Future<void> _onConnectivityChanged(
    List<ConnectivityResult> results,
    String deviceName,
  ) async {
    if (!_running) return;
    debugPrint('🔄 Network changed: $results');

    _discoveredDevices.clear();
    _devicesController.add([]);
    await _updateLocalIps();

    _reopenTimer?.cancel();
    _reopenTimer = null;
    _isReopening = false;

    await _openSocket(deviceName);
  }

  // ── Socket Management ──────────────────────────────────

  void _safeCloseSocket() {
    try { _socket?.close(); } catch (_) {}
    _socket = null;
  }

  Future<void> _openSocket(String deviceName) async {
    if (_isReopening) {
      debugPrint('⏳ Socket open already in progress — skipping');
      return;
    }
    _isReopening = true;

    _safeCloseSocket();

    await Future.delayed(const Duration(milliseconds: 300));

    if (!_running) {
      _isReopening = false;
      return;
    }

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppConstants.discoveryPort,
        reuseAddress: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.multicastLoopback = false;

      await _updateLocalIps();

      try { _socket!.joinMulticast(InternetAddress("224.0.0.1")); } catch (_) {}

      _socket!.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final dg = _socket?.receive();
            if (dg != null) _handlePacket(dg);
          }
        },
        onError: (error) {
          if (!_running) return;
          final code = (error is SocketException) ? error.osError?.errorCode : null;
          debugPrint('⚠ Socket error [errno $code] — reopening in 4s...');
          _safeCloseSocket();
          _scheduleReopen(deviceName, delay: const Duration(seconds: 4));
        },
        cancelOnError: true,
      );

      _isReopening = false;
      debugPrint('✅ Socket opened on port ${AppConstants.discoveryPort}');
      _broadcastPresence(deviceName, isOnline: true);
    } on SocketException catch (e) {
      final code = e.osError?.errorCode;
      _safeCloseSocket();
      _isReopening = false;
      final delay = code == 10013
          ? const Duration(seconds: 6)
          : const Duration(seconds: 3);
      debugPrint('⚠ Bind failed [errno $code] — retry in ${delay.inSeconds}s');
      _scheduleReopen(deviceName, delay: delay);
    } catch (e) {
      debugPrint('❌ Unexpected error: $e');
      _safeCloseSocket();
      _isReopening = false;
      _scheduleReopen(deviceName, delay: const Duration(seconds: 3));
    }
  }

  void _scheduleReopen(String deviceName, {required Duration delay}) {
    _reopenTimer?.cancel();
    _isReopening = false;
    _reopenTimer = Timer(delay, () {
      if (_running) _openSocket(deviceName);
    });
  }

  // ── Packet Handling ────────────────────────────────────

  void _handlePacket(Datagram dg) {
    if (!_localIps.contains(dg.address.address)) {
      _updateLocalIps().then((_) {
        if (_running && !_localIps.contains(dg.address.address)) {
          _processPacket(dg);
        }
      });
      return;
    }
  }

  void _processPacket(Datagram dg) {
    try {
      final json = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (json['type'] != 'DAPHQ_DISCOVERY') return;

      final ip = dg.address.address;

      if (json['status'] == 'OFFLINE') {
        if (_discoveredDevices.remove(ip) != null) {
          _devicesController.add(_discoveredDevices.values.toList());
        }
        return;
      }

      final device = DiscoveryModel.fromJson(json, ip);
      _discoveredDevices[ip] = device;
      _devicesController.add(_discoveredDevices.values.toList());
    } catch (_) {}
  }

  // ── Broadcasting ───────────────────────────────────────

  Future<void> _broadcastPresence(String deviceName, {bool isOnline = true}) async {
    if (_socket == null) return;

    try {
      final bytes = utf8.encode(jsonEncode({
        'type': 'DAPHQ_DISCOVERY',
        'name': deviceName,
        'status': isOnline ? 'ONLINE' : 'OFFLINE',
      }));

      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.contains('vbox') || name.contains('vmware') ||
            name.contains('wsl')  || name.contains('veth')) continue;

        for (final addr in interface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;

          final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';

          try { _socket?.send(bytes, InternetAddress(subnetBroadcast),   AppConstants.discoveryPort); } catch (_) {}
          try { _socket?.send(bytes, InternetAddress('255.255.255.255'), AppConstants.discoveryPort); } catch (_) {}
          try { _socket?.send(bytes, InternetAddress('224.0.0.1'),       AppConstants.discoveryPort); } catch (_) {}

          try {
            final tmp = await RawDatagramSocket.bind(addr, 0)
                .timeout(const Duration(milliseconds: 500));
            tmp.broadcastEnabled = true;
            tmp.send(bytes, InternetAddress(subnetBroadcast),   AppConstants.discoveryPort);
            tmp.send(bytes, InternetAddress('255.255.255.255'), AppConstants.discoveryPort);
            tmp.close();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // ── Cleanup ────────────────────────────────────────────

  void _cleanupDevices() {
    final now = DateTime.now();
    bool changed = false;
    _discoveredDevices.removeWhere((ip, device) {
      if (now.difference(device.lastSeen).inSeconds >
          AppConstants.discoveryIntervalSeconds * 3) {
        changed = true;
        return true;
      }
      return false;
    });
    if (changed) _devicesController.add(_discoveredDevices.values.toList());
  }

  // ── Helpers ────────────────────────────────────────────

  Future<void> _updateLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
      _localIps = {
        for (final i in interfaces)
          for (final a in i.addresses) a.address,
      };
    } catch (_) {}
  }
}