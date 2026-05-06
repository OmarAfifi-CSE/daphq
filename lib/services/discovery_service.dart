import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/discovery_model.dart';
import '../core/app_constants.dart';

class DiscoveryService {
  RawDatagramSocket? _socket;
  final StreamController<List<DiscoveryModel>> _devicesController =
      StreamController<List<DiscoveryModel>>.broadcast();
  final Map<String, DiscoveryModel> _discoveredDevices = {};
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Set<String> _localIps = {};
  String? _lastDeviceName;
  bool isDiscoverable = true;

  Stream<List<DiscoveryModel>> get devicesStream => _devicesController.stream;

  Future<void> startDiscovery(String deviceName) async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppConstants.discoveryPort,
        reuseAddress: true,
      );
      _socket!.broadcastEnabled = true;
      _socket!.multicastLoopback = false;
      _lastDeviceName = deviceName;

      // Initial local IP cache
      _updateLocalIps();

      // Join multicast group for better reliability across different media (Ethernet/Wi-Fi)
      try {
        _socket!.joinMulticast(InternetAddress("224.0.0.1"));
      } catch (_) {}

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _socket!.receive();
          if (dg != null) {
            _handlePacket(dg);
          }
        }
      });

      _broadcastTimer = Timer.periodic(
        const Duration(seconds: AppConstants.discoveryIntervalSeconds),
        (_) {
          if (isDiscoverable) {
            _broadcastPresence(deviceName, isOnline: true);
          }
        },
      );

      _cleanupTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) {
          _cleanupDevices();
          _updateLocalIps(); // Refresh local IPs periodically
        },
      );

      _broadcastPresence(deviceName, isOnline: true);
    } catch (e) {
      debugPrint("Discovery Error: $e");
    }
  }

  void _handlePacket(Datagram dg) {
    try {
      if (_localIps.contains(dg.address.address)) return;

      String data = utf8.decode(dg.data);
      Map<String, dynamic> json = jsonDecode(data);
      if (json['type'] == 'DAPHQ_DISCOVERY') {
        if (json['status'] == 'OFFLINE') {
          if (_discoveredDevices.containsKey(dg.address.address)) {
            _discoveredDevices.remove(dg.address.address);
            _devicesController.add(_discoveredDevices.values.toList());
          }
          return;
        }
        final device = DiscoveryModel.fromJson(json, dg.address.address);
        _discoveredDevices[device.ip] = device;
        _devicesController.add(_discoveredDevices.values.toList());
      }
    } catch (_) {}
  }

  Future<void> _updateLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
      _localIps = interfaces
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .toSet();
    } catch (_) {}
  }

  void triggerBroadcast({bool isOnline = true}) {
    isDiscoverable = isOnline;
    if (_lastDeviceName != null) {
      _broadcastPresence(_lastDeviceName!, isOnline: isOnline);
    }
  }

  Future<void> _broadcastPresence(String deviceName, {bool isOnline = true}) async {
    if (_socket == null) return;

    try {
      final data = jsonEncode({
        'type': 'DAPHQ_DISCOVERY',
        'name': deviceName,
        'status': isOnline ? 'ONLINE' : 'OFFLINE',
      });
      final bytes = utf8.encode(data);

      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (var interface in interfaces) {
        final name = interface.name.toLowerCase();
        // Skip obvious virtual ones
        if (name.contains('vbox') || name.contains('vmware') || name.contains('wsl') || name.contains('veth')) {
          continue;
        }

        for (var addr in interface.addresses) {
          final ipParts = addr.address.split('.');
          if (ipParts.length == 4) {
            final subnetBroadcast = "${ipParts[0]}.${ipParts[1]}.${ipParts[2]}.255";
            
            // Send from the main socket
            _socket!.send(bytes, InternetAddress(subnetBroadcast), AppConstants.discoveryPort);
            _socket!.send(bytes, InternetAddress("255.255.255.255"), AppConstants.discoveryPort);
            _socket!.send(bytes, InternetAddress("224.0.0.1"), AppConstants.discoveryPort);

            // SPECIAL TRICK: Bind a temporary socket to this specific IP to FORCE 
            // the broadcast through this physical interface (crucial for Ethernet vs Wi-Fi)
            try {
              final tempSocket = await RawDatagramSocket.bind(addr, 0);
              tempSocket.broadcastEnabled = true;
              tempSocket.send(bytes, InternetAddress(subnetBroadcast), AppConstants.discoveryPort);
              tempSocket.send(bytes, InternetAddress("255.255.255.255"), AppConstants.discoveryPort);
              tempSocket.close();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  void _cleanupDevices() {
    final now = DateTime.now();
    bool changed = false;
    _discoveredDevices.removeWhere((ip, device) {
      // Increase timeout to 30 seconds to handle unstable networks
      if (now.difference(device.lastSeen).inSeconds > 30) {
        changed = true;
        return true;
      }
      return false;
    });

    if (changed) {
      _devicesController.add(_discoveredDevices.values.toList());
    }
  }

  void stop() {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;
  }
}
