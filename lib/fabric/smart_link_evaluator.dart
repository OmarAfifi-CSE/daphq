import 'package:flutter/foundation.dart';

import 'peer_models.dart';

enum LinkExecutionStrategy {
  lanTriggeredDirectP2p,
  bleTriggeredDirectP2p,
  lanTlsDirect,
  unreachable,
  legacyPlainLan,
}

@immutable
class LocalRadioCapabilities {
  final bool hasWifi;
  final bool hasBle;
  final bool canHostDirect5g;
  final PeerPlatform localPlatform;
  final bool wifiHardwarePresent;
  final bool bluetoothHardwarePresent;
  final bool wifiEnabled;
  final bool bluetoothEnabled;
  final bool missingWifiPermission;
  final bool missingBlePermission;
  final bool locationServiceEnabled;

  const LocalRadioCapabilities({
    required this.hasWifi,
    required this.hasBle,
    required this.canHostDirect5g,
    required this.localPlatform,
    bool? wifiHardwarePresent,
    bool? bluetoothHardwarePresent,
    bool? wifiEnabled,
    bool? bluetoothEnabled,
    this.missingWifiPermission = false,
    this.missingBlePermission = false,
    this.locationServiceEnabled = true,
  })  : wifiHardwarePresent = wifiHardwarePresent ?? hasWifi,
        bluetoothHardwarePresent = bluetoothHardwarePresent ?? hasBle,
        wifiEnabled = wifiEnabled ?? hasWifi,
        bluetoothEnabled = bluetoothEnabled ?? hasBle;

  factory LocalRadioCapabilities.fallbackForPlatform(PeerPlatform platform) {
    return LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: false,
      localPlatform: platform,
      wifiHardwarePresent: true,
      bluetoothHardwarePresent: false,
      wifiEnabled: true,
      bluetoothEnabled: false,
      missingWifiPermission: false,
      missingBlePermission: false,
      locationServiceEnabled: true,
    );
  }

  /// Returns a copy of these capabilities with the given fields replaced.
  LocalRadioCapabilities copyWith({
    bool? hasWifi,
    bool? hasBle,
    bool? canHostDirect5g,
    PeerPlatform? localPlatform,
    bool? wifiHardwarePresent,
    bool? bluetoothHardwarePresent,
    bool? wifiEnabled,
    bool? bluetoothEnabled,
    bool? missingWifiPermission,
    bool? missingBlePermission,
    bool? locationServiceEnabled,
  }) {
    return LocalRadioCapabilities(
      hasWifi: hasWifi ?? this.hasWifi,
      hasBle: hasBle ?? this.hasBle,
      canHostDirect5g: canHostDirect5g ?? this.canHostDirect5g,
      localPlatform: localPlatform ?? this.localPlatform,
      wifiHardwarePresent: wifiHardwarePresent ?? this.wifiHardwarePresent,
      bluetoothHardwarePresent:
          bluetoothHardwarePresent ?? this.bluetoothHardwarePresent,
      wifiEnabled: wifiEnabled ?? this.wifiEnabled,
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      missingWifiPermission:
          missingWifiPermission ?? this.missingWifiPermission,
      missingBlePermission: missingBlePermission ?? this.missingBlePermission,
      locationServiceEnabled:
          locationServiceEnabled ?? this.locationServiceEnabled,
    );
  }

  bool get canUseDirectWifi =>
      hasWifi && !missingWifiPermission && locationServiceEnabled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocalRadioCapabilities &&
          runtimeType == other.runtimeType &&
          hasWifi == other.hasWifi &&
          hasBle == other.hasBle &&
          canHostDirect5g == other.canHostDirect5g &&
          localPlatform == other.localPlatform &&
          wifiHardwarePresent == other.wifiHardwarePresent &&
          bluetoothHardwarePresent == other.bluetoothHardwarePresent &&
          wifiEnabled == other.wifiEnabled &&
          bluetoothEnabled == other.bluetoothEnabled &&
          missingWifiPermission == other.missingWifiPermission &&
          missingBlePermission == other.missingBlePermission &&
          locationServiceEnabled == other.locationServiceEnabled;

  @override
  int get hashCode => Object.hash(
        hasWifi,
        hasBle,
        canHostDirect5g,
        localPlatform,
        wifiHardwarePresent,
        bluetoothHardwarePresent,
        wifiEnabled,
        bluetoothEnabled,
        missingWifiPermission,
        missingBlePermission,
        locationServiceEnabled,
      );
}

@immutable
class LinkPlan {
  final LinkExecutionStrategy strategy;
  final bool useTls;
  final int parallelStreams;
  final bool useReverseConnect;
  final bool shouldLocalHostDirectGroup;
  final String reason;

  const LinkPlan({
    required this.strategy,
    required this.useTls,
    required this.parallelStreams,
    required this.useReverseConnect,
    required this.shouldLocalHostDirectGroup,
    required this.reason,
  });
}

/// Evaluates the highest-speed transport path for sending files to [UnifiedPeer].
///
/// Always prefers a Direct 5GHz Wi-Fi P2P / SoftAP virtual link first (bootstrapped
/// over Router LAN when visible — needing zero Bluetooth — or via BLE GATT offline),
/// falling back transparently to multi-stream TLS LAN only when Direct radios/paths
/// are unavailable.
class SmartLinkEvaluator {
  const SmartLinkEvaluator();

  /// Returns true when [ip] belongs to a dedicated Hotspot subnet
  /// (`192.168.137.*` Windows Mobile Hotspot, `192.168.43.*` / `172.20.10.*`
  /// Personal Hotspot). When the peer is already on a direct Hotspot subnet,
  /// we transfer immediately over that Hotspot without tearing it down.
  static bool isDirectHotspotOrP2pSubnetIp(String? ip) {
    if (ip == null || ip.isEmpty) return false;
    return ip.startsWith('192.168.137.') ||
        ip.startsWith('192.168.43.') ||
        ip.startsWith('172.20.10.');
  }

  LinkPlan planTransfer({
    required UnifiedPeer peer,
    required LocalRadioCapabilities localCaps,
    required String localPeerId,
    bool lanProbeHealthy = true,
  }) {
    if (peer.isLegacyV1) {
      return const LinkPlan(
        strategy: LinkExecutionStrategy.legacyPlainLan,
        useTls: false,
        parallelStreams: 1,
        useReverseConnect: false,
        shouldLocalHostDirectGroup: false,
        reason: 'Legacy v1 peer on LAN',
      );
    }

    final int streams = peer.caps.multiStreamSupported ? 4 : 1;
    final bool tls = peer.caps.tlsSupported;

    // 0. If the user ALREADY connected the devices over a direct Hotspot
    // (Windows Mobile Hotspot 192.168.137.x or Phone Hotspot 192.168.43.x / 192.168.49.x),
    // use that Hotspot directly at full speed — NEVER tear it down or start a new AP!
    if (peer.hasLan &&
        lanProbeHealthy &&
        isDirectHotspotOrP2pSubnetIp(peer.lanIp)) {
      return LinkPlan(
        strategy: LinkExecutionStrategy.lanTlsDirect,
        useTls: tls,
        parallelStreams: streams,
        useReverseConnect: false,
        shouldLocalHostDirectGroup: false,
        reason: 'Direct Hotspot',
      );
    }
    final bool localCanHostGroup = localCaps.canHostDirect5g ||
        (localCaps.localPlatform == PeerPlatform.android &&
            localCaps.canUseDirectWifi);
    final bool peerCanHostGroup = peer.caps.direct5gHostCapable ||
        (peer.platform == PeerPlatform.android &&
            peer.caps.directClientCapable);
    final bool canFormDirectLink = localCaps.canUseDirectWifi &&
        peer.supportsDirect &&
        (localCanHostGroup || peerCanHostGroup);

    // 1. Best path: Bootstrap Direct 5GHz virtual network over LAN (zero Bluetooth required).
    if (canFormDirectLink && peer.hasLan && lanProbeHealthy) {
      return _buildDirectP2pPlan(
        strategy: LinkExecutionStrategy.lanTriggeredDirectP2p,
        peer: peer,
        localCaps: localCaps,
        localPeerId: localPeerId,
        useTls: tls,
        streams: streams,
        reason: 'Direct 5GHz Wi-Fi (LAN bootstrap)',
      );
    }

    // 2. Offline / LAN-unhealthy fallback: Bootstrap Direct 5GHz via BLE GATT handshake.
    if (canFormDirectLink && peer.hasBle && localCaps.hasBle) {
      return _buildDirectP2pPlan(
        strategy: LinkExecutionStrategy.bleTriggeredDirectP2p,
        peer: peer,
        localCaps: localCaps,
        localPeerId: localPeerId,
        useTls: tls,
        streams: streams,
        reason: 'Zero-Router Direct 5GHz Link via BLE',
      );
    }

    // 3. Hardware lacks Wi-Fi (e.g., Ethernet desktop) or peer/LAN cannot form Direct P2P.
    if (peer.hasLan) {
      return LinkPlan(
        strategy: LinkExecutionStrategy.lanTlsDirect,
        useTls: tls,
        parallelStreams: streams,
        useReverseConnect: false,
        shouldLocalHostDirectGroup: false,
        reason: _lanFallbackReason(localCaps, peer, streams, lanProbeHealthy),
      );
    }

    // 4. Peer only visible over BLE without compatible local radios/permissions.
    return LinkPlan(
      strategy: LinkExecutionStrategy.unreachable,
      useTls: tls,
      parallelStreams: streams,
      useReverseConnect: false,
      shouldLocalHostDirectGroup: false,
      reason: _unreachableReason(localCaps),
    );
  }

  String _lanFallbackReason(
    LocalRadioCapabilities localCaps,
    UnifiedPeer peer,
    int streams,
    bool lanProbeHealthy,
  ) {
    if (!localCaps.wifiHardwarePresent) {
      return 'Router LAN ($streams streams) — No Wi-Fi adapter on this device';
    }
    if (!localCaps.wifiEnabled) {
      return 'Router LAN ($streams streams) — Turn on Wi-Fi for Direct 5GHz';
    }
    if (localCaps.missingWifiPermission) {
      return 'Router LAN ($streams streams) — Allow Nearby Wi-Fi for Direct 5GHz';
    }
    if (!localCaps.locationServiceEnabled) {
      return 'Router LAN ($streams streams) — Turn on Location for Direct 5GHz';
    }
    if (!peer.supportsDirect) {
      return 'Router LAN ($streams streams) — Receiver Direct Wi-Fi unavailable';
    }
    if (!lanProbeHealthy) {
      return 'Router LAN fallback ($streams streams)';
    }
    return 'Router LAN ($streams streams)';
  }

  String _unreachableReason(LocalRadioCapabilities localCaps) {
    if (!localCaps.wifiHardwarePresent) {
      return 'Device lacks Wi-Fi hardware; connect both devices to the same router/Ethernet';
    }
    if (!localCaps.wifiEnabled) {
      return 'Turn on Wi-Fi to connect over Direct 5GHz';
    }
    if (localCaps.missingWifiPermission) {
      return 'Allow Nearby Wi-Fi permission to connect over Direct 5GHz';
    }
    if (!localCaps.locationServiceEnabled) {
      return 'Turn on Location to enable Wi-Fi Direct';
    }
    if (!localCaps.bluetoothEnabled && localCaps.bluetoothHardwarePresent) {
      return 'Connect to the same Wi-Fi or turn on Bluetooth';
    }
    return 'Peer unreachable; connect both devices to the same network';
  }

  LinkPlan _buildDirectP2pPlan({
    required LinkExecutionStrategy strategy,
    required UnifiedPeer peer,
    required LocalRadioCapabilities localCaps,
    required String localPeerId,
    required bool useTls,
    required int streams,
    required String reason,
  }) {
    // Group Owner selection rules avoiding Windows Defender Public inbound firewall drops
    // and unlocking true Windows 5GHz Mobile Hotspot hardware speeds:
    // - Android <-> Windows when Windows can host 5GHz AP: Windows hosts 5GHz Mobile Hotspot
    //   and Windows ALWAYS dials outbound TCP to Android (zero inbound Windows firewall issues,
    //   zero Bitdefender foreign-SSID prompts).
    // - Android <-> Windows when Windows cannot host 5GHz AP (e.g. offline): Android hosts
    //   5GHz P2P/SoftAP and Windows still dials outbound TCP to Android.
    // - Android <-> Android / Windows <-> Windows: deterministic tie-breaker on capabilities & peerId.
    final bool localHostsGo;
    if (localCaps.localPlatform == PeerPlatform.android &&
        peer.platform == PeerPlatform.windows) {
      if (localCaps.canHostDirect5g) {
        // Android 5 GHz Host (SoftAP/P2P) avoids the OS Wi-Fi picker popup
        // AND bypasses Windows Ethernet-only regulatory limits.
        localHostsGo = true;
      } else if (peer.caps.direct5gHostCapable) {
        localHostsGo = false;
      } else {
        localHostsGo = true;
      }
    } else if (localCaps.localPlatform == PeerPlatform.windows &&
        peer.platform == PeerPlatform.android) {
      if (peer.caps.direct5gHostCapable) {
        localHostsGo = false;
      } else if (localCaps.canHostDirect5g) {
        localHostsGo = true;
      } else if (peer.caps.directClientCapable) {
        localHostsGo = false;
      } else {
        localHostsGo = true;
      }
    } else if (localCaps.canHostDirect5g != peer.caps.direct5gHostCapable) {
      localHostsGo = localCaps.canHostDirect5g;
    } else {
      localHostsGo = localPeerId.compareTo(peer.peerId) <= 0;
    }

    // Enforce outbound-from-Windows TCP initiation across all Android <-> Windows pairs.
    final bool useReverseConnect;
    if (localCaps.localPlatform == PeerPlatform.android &&
        peer.platform == PeerPlatform.windows) {
      useReverseConnect = true;
    } else if (localCaps.localPlatform == PeerPlatform.windows &&
        peer.platform == PeerPlatform.android) {
      useReverseConnect = false;
    } else {
      useReverseConnect = localHostsGo;
    }

    return LinkPlan(
      strategy: strategy,
      useTls: useTls,
      parallelStreams: streams,
      useReverseConnect: useReverseConnect,
      shouldLocalHostDirectGroup: localHostsGo,
      reason: reason,
    );
  }
}
