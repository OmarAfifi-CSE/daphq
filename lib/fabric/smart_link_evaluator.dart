import 'package:flutter/foundation.dart';

import 'peer_models.dart';

enum LinkExecutionStrategy {
  lanTlsDirect,
  bleTriggeredDirectP2p,
  manualQrFallback,
  legacyPlainLan,
}

@immutable
class LocalRadioCapabilities {
  final bool hasWifi;
  final bool hasBle;
  final bool canHostDirect5g;
  final PeerPlatform localPlatform;

  const LocalRadioCapabilities({
    required this.hasWifi,
    required this.hasBle,
    required this.canHostDirect5g,
    required this.localPlatform,
  });

  factory LocalRadioCapabilities.fallbackForPlatform(PeerPlatform platform) {
    return LocalRadioCapabilities(
      hasWifi: true,
      hasBle: false,
      canHostDirect5g: false,
      localPlatform: platform,
    );
  }
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

/// Evaluates the optimal zero-router / hybrid transport strategy for sending files
/// between the local device and any discovered [UnifiedPeer].
class SmartLinkEvaluator {
  const SmartLinkEvaluator();

  LinkPlan planTransfer({
    required UnifiedPeer peer,
    required TransportPreference preference,
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
    final bool canUseDirectP2p = peer.hasBle &&
        localCaps.hasBle &&
        localCaps.hasWifi &&
        peer.supportsDirect;

    if (preference == TransportPreference.lanOnly) {
      if (peer.hasLan) {
        return LinkPlan(
          strategy: LinkExecutionStrategy.lanTlsDirect,
          useTls: tls,
          parallelStreams: streams,
          useReverseConnect: false,
          shouldLocalHostDirectGroup: false,
          reason: 'LAN TLS Multi-Stream ($streams streams)',
        );
      }
      return LinkPlan(
        strategy: LinkExecutionStrategy.manualQrFallback,
        useTls: tls,
        parallelStreams: streams,
        useReverseConnect: false,
        shouldLocalHostDirectGroup: false,
        reason: 'No LAN IP available in LAN-only mode; pair via QR',
      );
    }

    if (preference == TransportPreference.directTurbo) {
      if (canUseDirectP2p) {
        return _buildDirectP2pPlan(
          peer: peer,
          localCaps: localCaps,
          localPeerId: localPeerId,
          useTls: tls,
          streams: streams,
          reason: 'Direct 5GHz Turbo Link via BLE handshake',
        );
      }
      if (peer.hasLan) {
        return LinkPlan(
          strategy: LinkExecutionStrategy.lanTlsDirect,
          useTls: tls,
          parallelStreams: streams,
          useReverseConnect: false,
          shouldLocalHostDirectGroup: false,
          reason: 'Fallback to fast LAN TLS (Direct P2P unavailable)',
        );
      }
      return LinkPlan(
        strategy: LinkExecutionStrategy.manualQrFallback,
        useTls: tls,
        parallelStreams: streams,
        useReverseConnect: false,
        shouldLocalHostDirectGroup: false,
        reason: 'Hardware lacks BLE/Wi-Fi Direct; use QR Pairing',
      );
    }

    // autoSmart (default):
    // 1. Prefer silent zero-prompt LAN TLS multi-stream when peer has healthy LAN reachability.
    if (peer.hasLan && lanProbeHealthy) {
      return LinkPlan(
        strategy: LinkExecutionStrategy.lanTlsDirect,
        useTls: tls,
        parallelStreams: streams,
        useReverseConnect: false,
        shouldLocalHostDirectGroup: false,
        reason: 'Fast LAN TLS ($streams streams)',
      );
    }

    // 2. Auto-escalate to Zero-Router Direct 5GHz Link over BLE when no router or isolated/degraded.
    if (canUseDirectP2p) {
      return _buildDirectP2pPlan(
        peer: peer,
        localCaps: localCaps,
        localPeerId: localPeerId,
        useTls: tls,
        streams: streams,
        reason: 'Zero-Router Direct 5GHz Link via BLE',
      );
    }

    // 3. Fallback to whatever LAN exists if Direct radios are absent (e.g. Ethernet PC).
    if (peer.hasLan) {
      return LinkPlan(
        strategy: LinkExecutionStrategy.lanTlsDirect,
        useTls: tls,
        parallelStreams: streams,
        useReverseConnect: false,
        shouldLocalHostDirectGroup: false,
        reason: 'LAN TLS fallback',
      );
    }

    // 4. Out-of-band QR Pairing fallback when Bluetooth or Wi-Fi is unavailable.
    return LinkPlan(
      strategy: LinkExecutionStrategy.manualQrFallback,
      useTls: tls,
      parallelStreams: streams,
      useReverseConnect: false,
      shouldLocalHostDirectGroup: false,
      reason: 'Use QR Code / Token Pairing',
    );
  }

  LinkPlan _buildDirectP2pPlan({
    required UnifiedPeer peer,
    required LocalRadioCapabilities localCaps,
    required String localPeerId,
    required bool useTls,
    required int streams,
    required String reason,
  }) {
    // Group Owner selection rules avoiding Windows Defender Public inbound firewall drops:
    // - Android <-> Windows: Android hosts 5GHz GO / SoftAP; Windows connects via WlanConnect without Admin rights.
    // - Android <-> Android / Windows <-> Windows: deterministic tie-breaker on peer capabilities & peerId.
    final bool localHostsGo;
    if (localCaps.localPlatform == PeerPlatform.android &&
        peer.platform == PeerPlatform.windows &&
        localCaps.hasWifi) {
      localHostsGo = true;
    } else if (localCaps.localPlatform == PeerPlatform.windows &&
        peer.platform == PeerPlatform.android &&
        peer.caps.direct5gHostCapable) {
      localHostsGo = false;
    } else if (localCaps.canHostDirect5g != peer.caps.direct5gHostCapable) {
      localHostsGo = localCaps.canHostDirect5g;
    } else {
      localHostsGo = localPeerId.compareTo(peer.peerId) <= 0;
    }

    // Reverse-Connect requires Sender to host the Direct GO / SoftAP so Sender's
    // gateway IP is known over GATT before Receiver joins and dials outbound (bypassing
    // Windows Defender Public-profile inbound drops without Admin rights).
    final bool useReverseConnect = localHostsGo;

    return LinkPlan(
      strategy: LinkExecutionStrategy.bleTriggeredDirectP2p,
      useTls: useTls,
      parallelStreams: streams,
      useReverseConnect: useReverseConnect,
      shouldLocalHostDirectGroup: localHostsGo,
      reason: reason,
    );
  }
}
