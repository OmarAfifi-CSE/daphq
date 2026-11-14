# Daphq Zero-Router Direct Fabric — Architectural Design Specification

**Date:** 2026-11-13  
**Target Branch:** `feature/plan-execution-1`  
**Platforms:** Android (API 24–35) & Windows (10 1903+ / 11 Win32 C++/WinRT)  
**Scope:** Transform Daphq from router-dependent UDP/TCP into an automatic, zero-router, 5GHz Wi-Fi Direct + BLE adaptive high-speed transfer fabric with TLS encryption, device trust, QR fallback, and multi-stream TCP saturation.

---

## 1. Goals & Non-Goals

### Goals
1. **Zero-Router Instant Discovery:** Two devices opening Daphq detect each other immediately via **Bluetooth Low Energy (BLE)** alongside **LAN UDP** + **mDNS (`_daphq._tcp`)**, with no manual hotspot setup.
2. **Smart Adaptive Transport:**
   - Use **LAN TLS-TCP** silently (zero OS prompts) whenever both peers share a healthy fast local network (e.g., Gigabit Ethernet, Wi-Fi 6 without AP Isolation).
   - Automatically escalate to a **Direct 5GHz Wi-Fi Link (Wi-Fi Direct / SoftAP)** via encrypted **BLE GATT** credential exchange whenever there is no router, AP Isolation blocks discovery, LAN throughput is constrained, or the user toggles **Direct 5GHz Turbo**.
3. **Full Cross-Platform Matrix:** Support `Android ⇄ Android`, `Android ⇄ Windows`, and `Windows ⇄ Windows` Direct Links, with clean **QR Code / Token Pairing** fallback for desktop PCs without Bluetooth adapters and LAN fallback for Ethernet-only PCs without Wi-Fi.
4. **Saturated Link Speed (`Multi-Stream TLS TCP`):** Upgrade single-socket transfer to **TLS 1.3 (BoringSSL hardware AES/Crypto)** with **Adaptive Multi-Stream (`1–4` parallel streams)** while preserving atomic `.daphq-partial` staging, traversal protection, and `TransferPhase` invariants.
5. **Balanced Security & Zero-Friction Repeat Transfers:** Persistent local identity certificate per device, short 4-digit SAS verification code matching both screens, and **"Trust this device"** pairing so personal devices transfer effortlessly.

### Non-Goals
- Cloud relay / internet servers (100% local peer-to-peer).
- Google Play Services Nearby Connections dependency (no GMS lock-in).
- Removing existing Android Foreground Service lifecycle (`stopReceivingButton`, `cancelSendingButton`, `_prepareRequirements`, `requestAllPermissions`).

---

## 2. OS & Hardware Ground Truth Constraints

### 2.1 Windows 10 (1903+) & Windows 11
- **Unpackaged WinRT Compatibility:** `BluetoothLEAdvertisementPublisher`, `BluetoothLEAdvertisementWatcher`, `GattServiceProvider`, and `WiFiDirectAdvertisementPublisher` (`LegacySettings`) run directly inside an unpackaged Win32 binary via **Registration-Free WinRT** without requiring MSIX conversion.
  - **Constraint 1:** Never manually add `LocalName` or `Flags` sections in `BluetoothLEAdvertisementPublisher` (throws `ERROR_INVALID_PARAMETER` / access errors on Windows). Broadcast exclusively via **Manufacturer Data** (`CompanyId = 0x4451`, 24-byte compact beacon).
  - **Constraint 2:** Never call `NetworkOperatorTetheringManager` unpackaged (`wiFiControl` requires package identity). Always use `WiFiDirectAdvertisementPublisher` with `LegacySettings.IsEnabled = true` as the SoftAP host.
- **Standard-User Wi-Fi Profile Connection (`wlanapi.dll`):** Client connection uses **`WlanSaveTemporaryProfile`** (falling back to `WlanSetProfile` with `WLAN_PROFILE_USER`) + **`WlanConnect`** using WPA2-PSK AES XML — requires **zero admin elevation** and leaves no junk saved profiles after disconnect (`WlanDeleteProfile` / temporary memory scope).
- **Windows Defender Firewall `Public` Profile Workaround:** Newly created `WiFiDirect` adapters default to `Public` profile, blocking unsolicited inbound TCP SYN packets.
  - **Mandatory Design Rule (Reverse-Connect Protocol):** Whenever a transfer involves a Windows peer over a Direct P2P link, the Windows side initiates the **outbound** TCP socket(s) (`Socket.connect`) to the peer (which passes Windows Defender Firewall automatically with zero prompts or admin elevation), OR uses the bidirectional channel established outbound by Windows. The Windows installer may also optionally configure a program-scoped inbound rule, but correctness never depends on admin rights.
- **C++ Exception ABI Boundary (`windows/CMakeLists.txt`):** Because Flutter's Windows runner compiles with `_HAS_EXCEPTIONS=0`, all C++/WinRT code lives in an isolated static library target **`windows/direct/` (`daphq_direct_win`)** compiled with `/EHsc` and without `_HAS_EXCEPTIONS=0`. All `winrt::hresult_error` exceptions are caught inside the static library and returned as clean C ABI status codes/JSON events to `runner`.

### 2.2 Android 10–15 (`API 24–35`)
- **Permissions (`AndroidManifest.xml`):** Add strictly additive permissions:
  - `BLUETOOTH_SCAN` (with `neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` (Android 12+ / API 31+).
  - `NEARBY_WIFI_DEVICES` (with `neverForLocation`, Android 13+ / API 33+).
  - `ACCESS_FINE_LOCATION` scoped cleanly to `maxSdkVersion="32"` for Wi-Fi Direct / BLE scan on Android <= 12.
  - Preserve all existing storage, notification, wake lock, and foreground service permissions untouched.
- **Cellular Data Trap (`bindProcessToNetwork`):** When Android joins a no-internet P2P/SoftAP network (`removeCapability(NET_CAPABILITY_INTERNET)`), Dart's `Socket.connect` routes to cellular data unless the process is bound to the local `Network`.
  - Kotlin's `DirectLinkBridge` calls `connectivityManager.bindProcessToNetwork(network)` when entering an active Direct session and unconditionally resets `bindProcessToNetwork(null)` in `onLost` and teardown.
- **5GHz Group Creation:** Prefer `WifiP2pConfig.Builder().setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_5GHZ)` on Android 10+, falling back automatically to default band if hardware lacks 5GHz GO.
- **Single-Radio Concurrency Awareness (MCC/SCC):** Running P2P simultaneously with an active Wi-Fi AP on single-radio chipsets halves airtime; therefore `SmartLinkEvaluator` retains fast LAN when unobstructed and activates P2P selectively.

---

## 3. Architecture Overview

### 3.1 Layered Components (Dart Domain & Services)
1. **`lib/security/device_identity_service.dart`:**
   - Generates once and persists an ECDSA/RSA X.509 certificate + private key (`identity_cert.pem`, `identity_key.pem`) inside app support storage (`directoryProvider` injectable for tests).
   - Computes canonical `peerId` (8-byte hex/base64url prefix of public key SHA-256), full SHA-256 `certFingerprint`, `SecurityContext`, and 4-digit **SAS verification code** derived from symmetric sorted `[localFp, remoteFp]`.
2. **`lib/security/trusted_devices_service.dart`:**
   - Serialized JSON persistence (`_enqueue` pattern) of trusted `TrustedDevice` records (`peerId`, `certFingerprint`, `displayName`, `platform`, `trustedAt`, `lastSeen`).
   - Supports `isTrusted(peerId, certFingerprint)`, `trustDevice(...)`, `revokeDevice(peerId)`, `listTrustedDevices()`.
   - Fingerprint mismatch for an existing `peerId` is treated as untrusted and triggers an explicit MITM warning in `AuthDialog`.
3. **`lib/fabric/peer_models.dart` & `lib/fabric/ble_beacon_codec.dart`:**
   - Binary **22-byte Manufacturer Payload** codec (`CompanyId 0x4451` `'DQ'`) encoding: `version (1B)`, `capabilityFlags (1B: platform, direct5gHost, tlsSupported, busy)`, `peerId (8B)`, `fingerprintPrefix (8B)`, `transferPort (2B)`, `sessionNonce (2B)`.
   - `UnifiedPeer` aggregating `peerId`, `name`, `platform`, `lanIp`, `port`, `certFingerprint`, `bleAddress`, `caps`, `rssi`, `isTrusted`, `lastSeenLan`, `lastSeenBle`.
   - `PairingQrCodec`: encodes/decodes compact `daphq://pair?...` URI payload (`peerId`, `fp`, `lanIp`, `ssid`, `psk`, `port`, `hostOs`) with validation.
4. **`lib/fabric/peer_registry.dart`:**
   - Merges discovery events from LAN UDP (`DiscoveryService`) and BLE (`DirectNativeBridge`), deduplicates by `peerId` (with legacy IP fallback for `v1` peers), expires stale LAN/BLE records independently, and notifies `TransferCubit`.
5. **`lib/fabric/smart_link_evaluator.dart`:**
   - Evaluates connection strategy for a `UnifiedPeer` + user `TransportPreference` (`autoSmart`, `directTurbo`, `lanOnly`):
     - If `lanOnly` or peer has LAN-only capability (no Wi-Fi/BLE) and valid LAN probe -> uses **LAN TLS**.
     - If peer has no reachable LAN (no router / AP isolated), or `directTurbo` is selected -> negotiates **Direct 5GHz Link** over BLE GATT (`directExchange`), determines Group Owner (`GO`) + Reverse-Connect TCP role, activates OS P2P/WLAN join, binds Android `Network`, transfers via Multi-Stream TLS, and triggers clean teardown in `finally`.
6. **`lib/controllers/sender_controller.dart` & `lib/controllers/receiver_controller.dart`:**
   - Retain all existing v1 raw protocol compatibility (`v: 1`) while adding **v2 TLS + Multi-Stream (`1–4` sockets)**:
     - Optional `SecurityContext` on `ServerSocket`/`SecureServerSocket` and `onBadCertificate` fingerprint + trust pinning on client `SecureSocket`.
     - Protocol v2 handshake carries `protocolVersion: 2`, `peerId`, `fingerprint`, `streams` (`1–4`), `reverseConnect: bool`.
     - Multi-stream data channels transmit independent file batches or byte-range chunks (`[streamMagic + fileIndex + offset + length + bytes]`), serialized per-file onto `.daphq-partial` via sequential async write queues and flushed/renamed atomically before `{"s":"d"}` acknowledgment.

### 3.2 Native Bridges (`MethodChannel` + `EventChannel`)
- Channel name: **`com.omarafifi.daphq/direct_fabric`** (`Methods` + `Events` stream).
- **Android (`android/app/src/main/kotlin/com/omarafifi/daphq/DirectFabricHandler.kt`):**
  - BLE Scanner + Advertiser (`ManufacturerId = 0x4451`) + GATT Server (`0xD4F90001` service, characteristics `INFO` read + `LINK_CMD` write/notify) + GATT Client exchange.
  - Wi-Fi Direct (`WifiP2pManager` with 5GHz `WifiP2pConfig.Builder`) + `WifiNetworkSpecifier` (`removeCapability(NET_CAPABILITY_INTERNET)`) + `ConnectivityManager.bindProcessToNetwork(network)` lifecycle.
  - Clean fallback diagnostics when Bluetooth/Wi-Fi adapters are disabled or permissions denied.
- **Windows (`windows/direct/` static C++/WinRT lib + registration inside `flutter_window.cpp`):**
  - BLE Publisher & Watcher (`ManufacturerData` `0x4451`) + `GattServiceProvider` (`INFO` + `LINK_CMD`).
  - `WiFiDirectAdvertisementPublisher` (`LegacySettings` SoftAP SSID/passphrase + `WiFiDirectConnectionListener`) + `wlanapi.dll` (`WlanSaveTemporaryProfile` + `WlanConnect` + `WlanDisconnect` + interface IP polling).

---

## 4. Security Model & Failure Handling

1. **Authentication Flow:**
   - **Untrusted peer (first send):** Both sides compute identical 4-digit SAS from `(localFp, remoteFp)`. Receiver sees `AuthDialog` showing peer name, payload count/size, SAS code, `"Trust this device"` checkbox, and `Accept` / `Reject`.
   - **Trusted peer (`isTrusted == true` & matching cert fingerprint):** Passes certificate pinning & signed session proof silently (`autoAccept`) or shows minimal unobtrusive indicator if user disables auto-accept.
   - **Key rotation / spoofing alert:** If known `peerId` presents a different `certFingerprint`, trust is automatically bypassed and `AuthDialog` displays a high-visibility security warning.
2. **Error & Teardown Guarantees:**
   - BLE unavailable / denied -> graceful degradation to LAN + QR pairing without blocking launch.
   - Direct link handshake timeout (15s) or single-radio failure -> cancels P2P cleanly, clears `bindProcessToNetwork(null)` / `WlanDisconnect`, surfaces crisp message, and falls back to LAN if available.
   - Partial `.daphq-partial` files on all streams are closed and deleted atomically on any stream cancellation or failure.

---

## 5. Verification Strategy
- **Unit & Loopback Protocol Tests (Automated via `flutter test`):**
  1. Identity cert generation + SHA-256 fingerprint + SAS determinism + key mismatch rejection.
  2. `TrustedDevicesService` concurrent serialized persistence, revocation, and fingerprint verification.
  3. `BleBeaconCodec` 22-byte binary roundtrip + truncation/corruption bounds + `PairingQrCodec` roundtrip.
  4. `PeerRegistry` LAN+BLE merging, deduplication, and independent TTL expiry.
  5. `SmartLinkEvaluator` path selection matrix (`LAN Fast`, `No-LAN -> Direct`, `Turbo -> Direct`, `PC No-BLE -> QR/LAN`).
  6. Multi-Stream TLS transfer protocol tests (loopback TCP/TLS with `1` and `4` parallel streams, mixed sizes + 0-byte files + mid-transfer abort deleting all `.daphq-partial`).
- **UI & State Tests (`flutter test`):**
  - `OrbitalRadar` rendering unified LAN/BLE badges, `AuthDialog` SAS + Trust toggle, `QrPairingDialog`, `TrustedDevicesDialog`, zero `double.infinity`, zero overflow.
- **Native Platform Verification:**
  - Strict static & native compile verification (`flutter analyze` = 0 issues; Windows C++ static lib compilation verified cleanly if available; Android Gradle/Kotlin syntax verified cleanly without violating User Rule #3 on production release builds; physical hardware E2E test checklist for user validation across Android ⇄ Windows).
