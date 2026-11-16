import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/discovery_model.dart';
import '../fabric/peer_models.dart';
import '../core/app_constants.dart';

enum ServiceStatus { idle, discovering, recovering, failed, noConnection }

typedef UdpSocketBinder = Future<RawDatagramSocket> Function(
  dynamic host,
  int port, {
  bool reuseAddress,
});

class DiscoveryService {
  DiscoveryService({
    UdpSocketBinder? socketBinder,
    List<int>? candidatePorts,
    Future<bool> Function()? hasLocalNetwork,
    bool enableConnectivityListener = true,
    bool filterLocalIpPackets = true,
    Duration? conflictRetryDelay,
  })  : _socketBinder = socketBinder ?? _defaultSocketBinder,
        _candidatePorts = List<int>.unmodifiable(
          (candidatePorts == null || candidatePorts.isEmpty)
              ? AppConstants.discoveryPorts
              : candidatePorts,
        ),
        _hasLocalNetworkOverride = hasLocalNetwork,
        _enableConnectivityListener = enableConnectivityListener,
        _filterLocalIpPackets = filterLocalIpPackets,
        _conflictRetryDelay = conflictRetryDelay;

  static Future<RawDatagramSocket> _defaultSocketBinder(
    dynamic host,
    int port, {
    bool reuseAddress = true,
  }) {
    return RawDatagramSocket.bind(host, port, reuseAddress: reuseAddress);
  }

  final List<RawDatagramSocket> _sockets = <RawDatagramSocket>[];
  final UdpSocketBinder _socketBinder;
  final List<int> _candidatePorts;
  final Future<bool> Function()? _hasLocalNetworkOverride;
  final bool _enableConnectivityListener;
  final bool _filterLocalIpPackets;
  final Duration? _conflictRetryDelay;

  /// Ports currently bound by this discovery instance.
  List<int> get boundDiscoveryPorts =>
      List<int>.unmodifiable(_sockets.map((s) => s.port));

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
  bool _broadcastPaused = false;
  bool _isReopening = false;
  bool _watchdogActive = false;
  int _retryCount = 0;
  int _currentBackoffSeconds = 3;

  bool get isBroadcastPaused => _broadcastPaused;

  /// Suppresses periodic and triggered online UDP presence broadcasts while
  /// an active high-speed transfer is running to minimize airtime contention.
  void setBroadcastPaused(bool paused) {
    _broadcastPaused = paused;
  }

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
        if (_running && isDiscoverable && !_broadcastPaused) {
          _broadcastPresence(deviceName, isOnline: true);
        }
      },
    );

    _cleanupTimer = Timer.periodic(
      const Duration(seconds: AppConstants.discoveryIntervalSeconds),
      (_) => _cleanupDevices(),
    );

    if (_enableConnectivityListener) {
      try {
        _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
          (_) => _onConnectivityChanged(deviceName),
        );
      } catch (_) {}
    }
  }

  void triggerBroadcast({bool isOnline = true}) {
    isDiscoverable = isOnline;
    if (_broadcastPaused && isOnline) return;
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

  static bool isHotspotOrDirectIp(String? ip) {
    if (ip == null || ip.isEmpty) return false;
    return ip.startsWith('192.168.137.') ||
        ip.startsWith('192.168.49.') ||
        ip.startsWith('192.168.43.');
  }

  static bool isHotspotOrDirectAddress(InternetAddress addr) {
    return isHotspotOrDirectIp(addr.address);
  }

  static Future<String?> findActiveLocalHotspotIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (isHotspotOrDirectAddress(addr)) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return null;
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
      if (isVirtualInterfaceName(iface.name) &&
          !iface.addresses.any(isHotspotOrDirectAddress)) {
        return false;
      }
      return iface.addresses.any(isUsableAddress);
    });
  }

  static Future<String?> findBestLocalLanIp({String? preferSameSubnetAs}) async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      String? targetPrefix;
      if (preferSameSubnetAs != null && preferSameSubnetAs.isNotEmpty) {
        final parts = preferSameSubnetAs.split('.');
        if (parts.length == 4) {
          targetPrefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
        }
      }
      String? firstUsable;
      for (final iface in interfaces) {
        if (isVirtualInterfaceName(iface.name) &&
            !iface.addresses.any(isHotspotOrDirectAddress)) {
          continue;
        }
        for (final addr in iface.addresses) {
          if (!isUsableAddress(addr)) continue;
          if (targetPrefix != null && addr.address.startsWith(targetPrefix)) {
            return addr.address;
          }
          firstUsable ??= addr.address;
        }
      }
      return firstUsable;
    } catch (_) {}
    return null;
  }

  Future<bool> _hasLocalNetwork() async {
    final override = _hasLocalNetworkOverride;
    if (override != null) return override();
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
    for (final sock in List<RawDatagramSocket>.of(_sockets)) {
      try {
        sock.close();
      } catch (_) {}
    }
    _sockets.clear();
  }

  void _attachSocketListeners(RawDatagramSocket sock, String deviceName) {
    sock.listen(
      (RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          while (_running) {
            final dg = sock.receive();
            if (dg == null) break;
            _handlePacket(dg);
          }
        }
      },
      onError: (error) {
        if (!_running) return;
        if (Platform.isAndroid && error.toString().contains('errno = 101')) {
          return;
        }
        try {
          sock.close();
        } catch (_) {}
        _sockets.remove(sock);
        if (_sockets.isNotEmpty) {
          // Keep discovery alive as long as at least one port remains bound.
          return;
        }
        if (Platform.isWindows && error.toString().contains('errno = 1232')) {
          _isReopening = false;
          _scheduleReopen(
            deviceName,
            delay: const Duration(milliseconds: 500),
          );
          return;
        }
        _updateStatus(ServiceStatus.recovering);
        _scheduleReopen(deviceName, delay: const Duration(seconds: 4));
      },
      cancelOnError: false,
    );
  }

  Future<void> _openSocket(String deviceName) async {
    if (_isReopening) return;
    _isReopening = true;

    _safeCloseSocket();
    await Future.delayed(const Duration(milliseconds: 50));

    if (!_running) {
      _isReopening = false;
      return;
    }

    Object? lastError;
    try {
      bool boundFallback = false;
      for (int i = 0; i < _candidatePorts.length; i++) {
        // Bind primary legacy port (index 0) plus at most one non-excluded fallback
        // port so peers across both legacy (62005) and fallback (<49152) hear us.
        if (i > 0 && boundFallback) break;
        final candidatePort = _candidatePorts[i];
        try {
          final sock = await _socketBinder(
            InternetAddress.anyIPv4,
            candidatePort,
            reuseAddress: true,
          );
          if (!_running) {
            try {
              sock.close();
            } catch (_) {}
            _safeCloseSocket();
            _isReopening = false;
            return;
          }
          sock.broadcastEnabled = true;
          sock.multicastLoopback = false;
          if (!Platform.isAndroid) {
            try {
              sock.joinMulticast(InternetAddress("224.0.0.1"));
            } catch (_) {}
          }
          _sockets.add(sock);
          _attachSocketListeners(sock, deviceName);
          if (i > 0) boundFallback = true;
        } catch (e) {
          lastError = e;
        }
      }

      if (_sockets.isEmpty) {
        throw lastError ?? const SocketException('No discovery port available');
      }

      await _updateLocalIps();
      if (!_running) {
        _safeCloseSocket();
        _isReopening = false;
        return;
      }

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
      if (code == 10013) {
        _retryCount++;
        if (_retryCount > 1) {
          _updateStatus(ServiceStatus.failed);
          _updateLocalIps().then((_) {
            if (_running) _startFailedStateWatchdog(deviceName);
          });
          return;
        }
        _updateStatus(ServiceStatus.recovering);
        delay = _conflictRetryDelay ?? Duration(seconds: _currentBackoffSeconds);
        _currentBackoffSeconds = (_currentBackoffSeconds * 2).clamp(3, 30);
      } else {
        delay = _conflictRetryDelay ?? const Duration(seconds: 3);
        _updateStatus(ServiceStatus.recovering);
      }
      _scheduleReopen(deviceName, delay: delay);
    } catch (e) {
      _safeCloseSocket();
      _isReopening = false;
      _updateStatus(ServiceStatus.recovering);
      _scheduleReopen(
        deviceName,
        delay: _conflictRetryDelay ?? const Duration(seconds: 3),
      );
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
    if (_filterLocalIpPackets && _localIps.contains(dg.address.address)) return;
    _processPacket(dg);
  }

  void _processPacket(Datagram dg) {
    try {
      final json = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (json['type'] != 'DAPHQ_DISCOVERY') return;
      final incomingPeerId = json['peerId'] as String?;
      if (incomingPeerId != null &&
          _localPeerId != null &&
          incomingPeerId == _localPeerId) {
        return;
      }

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

  Future<void> _sendDatagram(
    RawDatagramSocket socket,
    List<int> bytes,
    InternetAddress address,
    int port,
  ) async {
    for (int attempt = 0; attempt < 4; attempt++) {
      if (!_running) return;
      try {
        final int sent = socket.send(bytes, address, port);
        if (sent > 0) return;
      } catch (_) {
        return;
      }
      // On Windows IOCP, RawDatagramSocket.send() returns 0 while a previous
      // overlapped WSASendTo is still draining; yield briefly before retrying.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> _broadcastPresence(
    String deviceName, {
    bool isOnline = true,
  }) async {
    if (_sockets.isEmpty || !_running) return;
    final primarySocket = _sockets.first;

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
      if (!_running || _sockets.isEmpty) return;

      for (final interface in interfaces) {
        if (isVirtualInterfaceName(interface.name) &&
            !interface.addresses.any(isHotspotOrDirectAddress)) {
          continue;
        }

        for (final addr in interface.addresses) {
          if (!isUsableAddress(addr)) {
            continue;
          }
          final parts = addr.address.split('.');
          if (parts.length != 4) {
            continue;
          }

          final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';

          for (final targetPort in _candidatePorts) {
            if (!_running || _sockets.isEmpty) return;
            await _sendDatagram(
              primarySocket,
              bytes,
              InternetAddress(subnetBroadcast),
              targetPort,
            );

            if (!Platform.isAndroid) {
              await _sendDatagram(
                primarySocket,
                bytes,
                InternetAddress('255.255.255.255'),
                targetPort,
              );
              await _sendDatagram(
                primarySocket,
                bytes,
                InternetAddress('224.0.0.1'),
                targetPort,
              );
            }
          }

          if (!_running) return;
          try {
            final tmp = await RawDatagramSocket.bind(
              addr,
              0,
            ).timeout(const Duration(milliseconds: 500));
            try {
              tmp.broadcastEnabled = true;
              for (final targetPort in _candidatePorts) {
                if (!_running) break;
                await _sendDatagram(
                  tmp,
                  bytes,
                  InternetAddress(subnetBroadcast),
                  targetPort,
                );
                if (!Platform.isAndroid) {
                  await _sendDatagram(
                    tmp,
                    bytes,
                    InternetAddress('255.255.255.255'),
                    targetPort,
                  );
                }
              }
            } finally {
              tmp.close();
            }
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
    if (_sockets.isNotEmpty && _status == ServiceStatus.discovering) {
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

      for (final candidatePort in _candidatePorts) {
        try {
          final test = await _socketBinder(
            InternetAddress.anyIPv4,
            candidatePort,
            reuseAddress: true,
          );
          test.close();
          timer.cancel();
          _watchdogActive = false;
          forceReopen();
          return;
        } catch (_) {}
      }
    });
  }
}
