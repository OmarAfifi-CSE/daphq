import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/discovery_model.dart';
import '../fabric/peer_models.dart';
import '../core/app_constants.dart';

enum ServiceStatus { idle, discovering, recovering, failed, noConnection }

class DiscoveryService {
  RawDatagramSocket? _socket;

  final StreamController<List<DiscoveryModel>> _devicesController =
      StreamController<List<DiscoveryModel>>.broadcast();

  final StreamController<DiscoveryModel> _heartbeatController =
      StreamController<DiscoveryModel>.broadcast();

  final StreamController<ServiceStatus> _statusController =
      StreamController<ServiceStatus>.broadcast();

  ServiceStatus _status = ServiceStatus.idle;
  ServiceStatus get status => _status;

  final Map<String, DiscoveryModel> _discoveredDevices = {};

  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _reopenTimer;
  Timer? _watchdogTimer;
  Timer? _connectivityPollTimer;
  StreamSubscription? _connectivitySubscription;

  final Set<String> _localIps = {};
  String? _lastDeviceName;
  String? _localPeerId;
  String? _localFingerprint;
  PeerCapabilities? _localCapabilities;
  int _listenPort = AppConstants.transferPort;
  bool isDiscoverable = true;
  bool _running = false;
  bool _isReopening = false;
  bool _watchdogActive = false;
  int _retryCount = 0;
  int _currentBackoffSeconds = 3;

  Stream<List<DiscoveryModel>> get devicesStream => _devicesController.stream;
  Stream<DiscoveryModel> get heartbeatStream => _heartbeatController.stream;
  Stream<ServiceStatus> get statusStream => _statusController.stream;

  void _updateStatus(ServiceStatus status) {
    if (_statusController.isClosed) return;
    if (!_running && status != ServiceStatus.idle) return;
    _status = status;
    _statusController.add(status);

    if (_running && status == ServiceStatus.noConnection) {
      _startConnectivityPolling();
    } else {
      _connectivityPollTimer?.cancel();
      _connectivityPollTimer = null;
    }
  }

  void _startConnectivityPolling() {
    _connectivityPollTimer?.cancel();
    _connectivityPollTimer = Timer.periodic(const Duration(seconds: 3), (
      timer,
    ) async {
      if (!_running || _status != ServiceStatus.noConnection) {
        timer.cancel();
        return;
      }
      if (await _hasLocalNetwork()) {
        timer.cancel();
        if (_lastDeviceName != null) {
          await _openSocket(_lastDeviceName!);
        }
      }
    });
  }

  void updateAdvertisementMetadata({
    String? peerId,
    String? certFingerprint,
    PeerCapabilities? capabilities,
    int? listenPort,
  }) {
    if (peerId != null) _localPeerId = peerId;
    if (certFingerprint != null) _localFingerprint = certFingerprint;
    if (capabilities != null) _localCapabilities = capabilities;
    if (listenPort != null) _listenPort = listenPort;
    if (_running && isDiscoverable && _lastDeviceName != null) {
      _broadcastPresence(_lastDeviceName!, isOnline: true);
    }
  }

  Future<void> startDiscovery(
    String deviceName, {
    String? peerId,
    String? certFingerprint,
    PeerCapabilities? capabilities,
    int? listenPort,
  }) async {
    if (_running) return;
    _running = true;
    _lastDeviceName = deviceName;
    if (peerId != null) _localPeerId = peerId;
    if (certFingerprint != null) _localFingerprint = certFingerprint;
    if (capabilities != null) _localCapabilities = capabilities;
    if (listenPort != null) _listenPort = listenPort;

    await _updateLocalIps();
    if (!_running || _devicesController.isClosed) return;

    if (await _hasLocalNetwork()) {
      if (!_running || _devicesController.isClosed) return;
      await _openSocket(deviceName);
    } else {
      _updateStatus(ServiceStatus.noConnection);
    }
    if (!_running || _devicesController.isClosed) return;

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

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (_) => _onConnectivityChanged(deviceName),
    );
  }

  void triggerBroadcast({bool isOnline = true}) {
    isDiscoverable = isOnline;
    if (_lastDeviceName != null) {
      _broadcastPresence(_lastDeviceName!, isOnline: isOnline);
    }
  }

  Future<void> forceReopen() async {
    if (!_running || _lastDeviceName == null) return;
    _retryCount = 0;
    _currentBackoffSeconds = 3;
    await _openSocket(_lastDeviceName!);
  }

  Future<void> stop() async {
    _running = false;
    _watchdogActive = false;
    _updateStatus(ServiceStatus.idle);
    _reopenTimer?.cancel();
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _watchdogTimer?.cancel();
    _connectivityPollTimer?.cancel();
    await _connectivitySubscription?.cancel();
    _reopenTimer =
        _broadcastTimer =
        _cleanupTimer =
        _watchdogTimer =
        _connectivityPollTimer = null;
    _connectivitySubscription = null;
    _safeCloseSocket();
  }

  void dispose() {
    stop();
    _devicesController.close();
    _heartbeatController.close();
    _statusController.close();
  }

  Future<void> _onConnectivityChanged(String deviceName) async {
    if (!_running) return;

    _discoveredDevices.clear();
    if (!_devicesController.isClosed) {
      _devicesController.add([]);
    }
    await _updateLocalIps();
    if (!_running) return;

    _reopenTimer?.cancel();
    _reopenTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _watchdogActive = false;
    _isReopening = false;
    _retryCount = 0;
    _currentBackoffSeconds = 3;

    if (!await _hasLocalNetwork()) {
      _updateStatus(ServiceStatus.noConnection);
      _safeCloseSocket();
      return;
    }

    await _openSocket(deviceName);
  }

  static bool isVirtualInterfaceName(String rawName) {
    final name = rawName.toLowerCase();
    const virtualKeywords = [
      'vbox',
      'vmware',
      'wsl',
      'veth',
      'vethernet',
      'virtual',
      'default switch',
      'pseudo',
      'teredo',
      'bluetooth',
      'tunnel',
      'loopback',
      'host-only',
      'npcap',
      'hyper-v',
      'microsoft',
      'wan miniport',
      'agile',
      'isatap',
      'ras',
      'vmnet',
      'docker',
      'tap',
      'tun',
      'tailscale',
      'zerotier',
      'wireguard',
      'wintun',
      'nordlynx',
      'proton',
      'mullvad',
      'openvpn',
      'hamachi',
      'radmin',
      'utun',
    ];
    if (virtualKeywords.any(name.contains)) return true;
    return RegExp(r'(^|[^a-z0-9])wg\d*($|[^a-z0-9])').hasMatch(name);
  }

  static bool isUsableAddress(InternetAddress addr) {
    final ip = addr.address;
    return !addr.isLoopback &&
        !ip.startsWith('169.254') &&
        !ip.startsWith('127.') &&
        !ip.startsWith('0.');
  }

  static bool hasUsableInterface(Iterable<NetworkInterface> interfaces) {
    return interfaces.any((iface) {
      if (isVirtualInterfaceName(iface.name)) return false;
      return iface.addresses.any(isUsableAddress);
    });
  }

  static Future<String?> findBestLocalLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        if (isVirtualInterfaceName(iface.name)) continue;
        for (final addr in iface.addresses) {
          if (isUsableAddress(addr)) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _hasLocalNetwork() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      return hasUsableInterface(interfaces);
    } catch (_) {
      return true;
    }
  }

  void _safeCloseSocket() {
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  Future<void> _openSocket(String deviceName) async {
    if (_isReopening) return;
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

      if (!Platform.isAndroid) {
        try {
          _socket!.joinMulticast(InternetAddress("224.0.0.1"));
        } catch (_) {}
      }

      _socket!.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final dg = _socket?.receive();
            if (dg != null) {
              _handlePacket(dg);
            }
          }
        },
        onError: (error) {
          if (!_running) return;
          if (Platform.isAndroid && error.toString().contains('errno = 101')) {
            return;
          }
          if (Platform.isWindows && error.toString().contains('errno = 1232')) {
            _safeCloseSocket();
            _isReopening = false;
            _scheduleReopen(
              deviceName,
              delay: const Duration(milliseconds: 500),
            );
            return;
          }
          _updateStatus(ServiceStatus.recovering);
          _safeCloseSocket();
          _scheduleReopen(deviceName, delay: const Duration(seconds: 4));
        },
        cancelOnError: false,
      );

      _isReopening = false;
      _retryCount = 0;
      _currentBackoffSeconds = 3;
      _watchdogActive = false;
      _updateStatus(ServiceStatus.discovering);

      _broadcastPresence(deviceName, isOnline: true);
    } on SocketException catch (e) {
      final code = e.osError?.errorCode;
      _safeCloseSocket();
      _isReopening = false;

      Duration delay;
      if (Platform.isWindows && code == 10013) {
        _retryCount++;
        if (_retryCount > 1) {
          _updateStatus(ServiceStatus.failed);
          _updateLocalIps().then((_) {
            if (_running) _startFailedStateWatchdog(deviceName);
          });
          return;
        }
        _updateStatus(ServiceStatus.recovering);
        delay = Duration(seconds: _currentBackoffSeconds);
        _currentBackoffSeconds = (_currentBackoffSeconds * 2).clamp(3, 30);
      } else {
        delay = const Duration(seconds: 3);
        _updateStatus(ServiceStatus.recovering);
      }
      _scheduleReopen(deviceName, delay: delay);
    } catch (e) {
      _safeCloseSocket();
      _isReopening = false;
      _updateStatus(ServiceStatus.recovering);
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

  void _handlePacket(Datagram dg) {
    if (!_running) return;
    if (_localIps.contains(dg.address.address)) return;
    _processPacket(dg);
  }

  void _processPacket(Datagram dg) {
    try {
      final json = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (json['type'] != 'DAPHQ_DISCOVERY') return;

      final ip = dg.address.address;

      if (json['status'] == 'OFFLINE') {
        if (_discoveredDevices.remove(ip) != null &&
            !_devicesController.isClosed) {
          _devicesController.add(_discoveredDevices.values.toList());
        }
        return;
      }

      final existing = _discoveredDevices[ip];
      final device = DiscoveryModel.fromJson(json, ip);
      _discoveredDevices[ip] = device;
      if (!_heartbeatController.isClosed) {
        _heartbeatController.add(device);
      }
      final bool changed =
          existing == null ||
          existing.name != device.name ||
          existing.peerId != device.peerId ||
          existing.certFingerprint != device.certFingerprint ||
          existing.port != device.port ||
          existing.caps != device.caps;
      if (changed && !_devicesController.isClosed) {
        _devicesController.add(_discoveredDevices.values.toList());
      }
    } catch (_) {}
  }

  Future<void> _broadcastPresence(
    String deviceName, {
    bool isOnline = true,
  }) async {
    if (_socket == null) return;

    try {
      final bytes = utf8.encode(
        jsonEncode({
          'type': 'DAPHQ_DISCOVERY',
          'name': deviceName,
          'status': isOnline ? 'ONLINE' : 'OFFLINE',
          'port': _listenPort,
          if (_localPeerId != null) 'peerId': _localPeerId,
          if (_localFingerprint != null) 'fp': _localFingerprint,
          if (_localCapabilities != null)
            'caps': _localCapabilities!.toFlagsByte(),
        }),
      );

      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        if (isVirtualInterfaceName(interface.name)) {
          continue;
        }

        for (final addr in interface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) {
            continue;
          }

          final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';

          try {
            _socket?.send(
              bytes,
              InternetAddress(subnetBroadcast),
              AppConstants.discoveryPort,
            );
          } catch (_) {}

          if (!Platform.isAndroid) {
            try {
              _socket?.send(
                bytes,
                InternetAddress('255.255.255.255'),
                AppConstants.discoveryPort,
              );
            } catch (_) {}
            try {
              _socket?.send(
                bytes,
                InternetAddress('224.0.0.1'),
                AppConstants.discoveryPort,
              );
            } catch (_) {}
          }

          try {
            final tmp = await RawDatagramSocket.bind(
              addr,
              0,
            ).timeout(const Duration(milliseconds: 500));
            tmp.broadcastEnabled = true;
            tmp.send(
              bytes,
              InternetAddress(subnetBroadcast),
              AppConstants.discoveryPort,
            );
            if (!Platform.isAndroid) {
              tmp.send(
                bytes,
                InternetAddress('255.255.255.255'),
                AppConstants.discoveryPort,
              );
            }
            tmp.close();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _cleanupDevices() async {
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
    if (changed && !_devicesController.isClosed) {
      _devicesController.add(_discoveredDevices.values.toList());
    }

    await _updateLocalIps();
    if (!_running) return;
    if (_socket != null && _status == ServiceStatus.discovering) {
      if (!await _hasLocalNetwork()) {
        _updateStatus(ServiceStatus.noConnection);
        _safeCloseSocket();
      }
    }
  }

  Future<void> _updateLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
      _localIps
        ..clear()
        ..addAll(
          interfaces.expand((i) => i.addresses.map((a) => a.address)),
        );
    } catch (_) {}
  }

  void _startFailedStateWatchdog(String deviceName) {
    _watchdogTimer?.cancel();
    _watchdogActive = true;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_running || !_watchdogActive) {
        timer.cancel();
        _watchdogActive = false;
        return;
      }

      try {
        final test = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          AppConstants.discoveryPort,
          reuseAddress: true,
        );
        test.close();
        timer.cancel();
        _watchdogActive = false;
        forceReopen();
      } catch (_) {}
    });
  }
}
