# Daphq Zero-Router Direct Fabric Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or strict TDD per task. Steps use checkbox (`- [ ]`) syntax for tracking. Execute strictly with RED -> Verify FAIL -> GREEN -> Verify PASS -> REFACTOR. Never run `git commit`, `git push`, or production `flutter build` autonomously.

**Goal:** Build the complete Cross-Platform Zero-Router Direct Transfer Fabric (`BLE Mesh + 5GHz Wi-Fi Direct/SoftAP + Adaptive Multi-Stream TLS + Device Trust + QR Pairing`) for `Android` and `Windows`.

**Architecture:** Dual-plane modular fabric separating Control/Discovery (`LAN UDP + Native BLE`) and Direct 5GHz Link Setup (`Android WifiP2p/WifiNetworkSpecifier` + `Windows C++/WinRT WiFiDirect & wlanapi`) from the unified Dart `TLS 1.3 + Multi-Stream` data streaming core, while preserving 100% of existing permissions, notifications (`stopReceivingButton`, `cancelSendingButton`), `.daphq-partial` atomic finalization, and `TransferPhase` invariants.

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4, `basic_utils ^5.8.2`, `qr_flutter ^4.1.0`, `crypto`, `flutter_bloc`, Android Kotlin (`WifiP2pManager`, `BluetoothLeAdvertiser/Scanner`, `BluetoothGattServer`, `ConnectivityManager`), Windows C++17 / WinRT (`Windows.Devices.Bluetooth.Advertisement`, `Windows.Devices.WiFiDirect`, `wlanapi.dll`).

**Spec:** `docs/superpowers/specs/2026-11-13-zero-router-direct-fabric-design.md`

## Global Constraints
- Static analysis (`flutter analyze`) MUST exit 0 with ZERO errors, warnings, and infos (`prefer_const_*`, `prefer_relative_imports`).
- Zero occurrences of `double.infinity` anywhere in `lib/`.
- Strict adherence to `.github/instructions/preserve_core_logic.md` (preserve `requestAllPermissions`, `FlutterForegroundTask.updateService`, `stopReceivingButton`, `cancelSendingButton`, `Future.delayed` values, `_prepareRequirements`).
- All Windows C++/WinRT code lives in an isolated `windows/direct/` library compiled with `/EHsc` (no `_HAS_EXCEPTIONS=0`), catching all exceptions before crossing C ABI into `windows/runner`.
- Never execute `git commit`, `git push`, or `flutter build` autonomously.

---

## Stage 1: Core Security, Identity, Binary Codecs & Multi-Stream TLS Engine (Dart)

### Task 1: Add Required Dart Dependencies (`basic_utils`, `qr_flutter`)
**Files:**
- Modify: `pubspec.yaml`
- [ ] Run `flutter pub add basic_utils qr_flutter` and verify resolution cleanly (`flutter pub get`).

### Task 2: `DeviceIdentityService` (X.509 Cert + SHA-256 Fingerprint + SAS PIN)
**Files:**
- Create: `lib/security/device_identity_service.dart`
- Test: `test/security_and_fabric_test.dart`
**Interfaces:**
- Produces `DeviceIdentity` (`peerId`, `certFingerprint`, `certificatePem`, `privateKeyPem`, `SecurityContext createServerContext()`, `String computeSasCode(String remoteFingerprint)`).
- [ ] **Step 1 (RED):** Write unit tests verifying deterministic identity reload from temp storage, distinct `peerId` across two fresh dirs, valid PEM chain loading into `SecurityContext`, and symmetric SAS computation (`computeSasCode(fpA, fpB) == computeSasCode(fpB, fpA)`).
- [ ] **Step 2:** Run `flutter test test/security_and_fabric_test.dart` -> verify FAIL.
- [ ] **Step 3 (GREEN):** Implement `DeviceIdentityService` using `basic_utils` (`CryptoUtils.generateEcKeyPair`, `X509Utils.generateSelfSignedCertificate` / RSA-2048 fallback, SHA-256 DER digest, atomic `.tmp` write).
- [ ] **Step 4:** Verify tests PASS + `flutter analyze` 0 issues.

### Task 3: `TrustedDevicesService` (Serialized Pairing Store & MITM Mismatch Detection)
**Files:**
- Create: `lib/security/trusted_devices_service.dart`
- Test: `test/security_and_fabric_test.dart`
**Interfaces:**
- Produces `TrustedDevice`, `TrustCheckResult` (`trusted`, `unknown`, `fingerprintMismatch`), `TrustedDevicesService.isTrusted(...)`, `trustDevice(...)`, `revokeDevice(...)`, `listTrustedDevices()`.
- [ ] **Step 1 (RED):** Test concurrent `trustDevice` writes, exact fingerprint match (`trusted`), changed fingerprint for same `peerId` (`fingerprintMismatch`), and `revokeDevice`.
- [ ] **Step 2:** Run test -> verify FAIL.
- [ ] **Step 3 (GREEN):** Implement serialized queue persistence (`_enqueue` + atomic write pattern matching `HistoryService`).
- [ ] **Step 4:** Verify PASS.

### Task 4: `BleBeaconCodec`, `PairingQrCodec`, `UnifiedPeer`, and `PeerRegistry`
**Files:**
- Create: `lib/fabric/peer_models.dart`
- Create: `lib/fabric/ble_beacon_codec.dart`
- Create: `lib/fabric/peer_registry.dart`
- Modify: `lib/models/discovery_model.dart` (additive fields `peerId`, `fingerprint`, `transportKind`, `directCapabilities`, keeping existing `ip`/`name` API intact)
- Test: `test/security_and_fabric_test.dart`
**Interfaces:**
- Produces `BleBeaconCodec` (22-byte Manufacturer Payload `companyId = 0x4451`), `PairingQrCodec.encode/decode` (`daphq://pair?...`), `PeerRegistry` (`upsertLanPeer`, `upsertBlePeer`, `removeOffline`, `pruneExpired`, `Stream<List<UnifiedPeer>>`).
- [ ] **Step 1 (RED):** Test binary 22-byte beacon encode/decode roundtrip, malformed length rejection, QR URI encode/decode roundtrip, and `PeerRegistry` deduplication when same `peerId` arrives from both LAN and BLE.
- [ ] **Step 2:** Run test -> verify FAIL.
- [ ] **Step 3 (GREEN):** Implement `peer_models.dart`, `ble_beacon_codec.dart`, `peer_registry.dart`, and additive `DiscoveryModel` extensions.
- [ ] **Step 4:** Verify PASS.

### Task 5: Upgrade `ReceiverController` & `SenderController` for TLS + Multi-Stream (`1–4` Parallel Streams) + Reverse-Connect Mode
**Files:**
- Modify: `lib/controllers/receiver_controller.dart`
- Modify: `lib/controllers/sender_controller.dart`
- Test: `test/transfer_protocol_test.dart`
**Interfaces:**
- Consumes: `DeviceIdentityService`, `SecurityContext`
- Produces: Optional `useTls`, `streamCount` (`1..4`), `expectedPeerFingerprint`, `onVerifyPeerTrust` callback, plus Multi-Stream chunk receiver (`RandomAccessFile` serialized per-file async writer preserving `.daphq-partial` atomic finalize) while staying 100% backward-compatible with v1 clients.
- [ ] **Step 1 (RED):** Add loopback protocol tests in `test/transfer_protocol_test.dart` for:
  - TLS pinned transfer (`SecureServerSocket` + `SecureSocket`) passing on matching fingerprint & rejecting spoofed cert (`fingerprint mismatch`).
  - 4-stream parallel transfer of large file (`>2 MB`) + mixed small files + 0-byte file verifying byte-for-byte integrity and atomic `.daphq-partial` cleanup on abort.
- [ ] **Step 2:** Run `flutter test test/transfer_protocol_test.dart` -> verify FAIL.
- [ ] **Step 3 (GREEN):** Implement TLS option + v2 multi-stream worker pool (Control stream 0 + Data streams `1..N`, per-file serialized write queue over `.daphq-partial`, aggregate speed & `TransferPhase` progress, `tcpNoDelay = true`).
- [ ] **Step 4:** Run full protocol suite (`flutter test test/transfer_protocol_test.dart`) -> verify PASS!

---

## Stage 2: Native Cross-Platform BLE & P2P Bridges (`Android Kotlin` + `Windows C++/WinRT`)

### Task 6: Dart `DirectNativeBridge` Contract & Event Stream
**Files:**
- Create: `lib/fabric/direct_native_bridge.dart`
- Create: `lib/fabric/smart_link_evaluator.dart`
- Test: `test/security_and_fabric_test.dart`
- [ ] **Step 1 (RED):** Write unit tests for `SmartLinkEvaluator` matrix (`autoSmart`, `directTurbo`, `lanOnly`, BLE-only peer -> Direct upgrade, PC Ethernet-only -> LAN, missing Bluetooth -> QR recommendation) + `DirectNativeBridge` channel parsing.
- [ ] **Step 2:** Run test -> FAIL.
- [ ] **Step 3 (GREEN):** Implement `DirectNativeBridge` (`MethodChannel` + `EventChannel` on `com.omarafifi.daphq/direct_fabric` with safe fallback when platform channel unavailable in unit tests) and `SmartLinkEvaluator`.
- [ ] **Step 4:** Verify PASS.

### Task 7: Android Native BLE + Wi-Fi Direct 5GHz + Network Binding (`DirectFabricHandler.kt`)
**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml` (additive `BLUETOOTH_*`, `NEARBY_WIFI_DEVICES neverForLocation`, `ACCESS_FINE_LOCATION maxSdkVersion="32"`)
- Create: `android/app/src/main/kotlin/com/omarafifi/daphq/DirectFabricHandler.kt`
- Modify: `android/app/src/main/kotlin/com/omarafifi/daphq/MainActivity.kt` (wire `DirectFabricHandler` + `onDestroy` cleanup)
- [ ] Implement full BLE `BluetoothLeAdvertiser` (`ManufacturerId = 0x4451`), `BluetoothLeScanner`, `BluetoothGattServer` (read peer info + write/notify direct link negotiation), `BluetoothGatt` client exchange.
- [ ] Implement `WifiP2pManager` (5GHz `GROUP_OWNER_BAND_5GHZ` with fallback + group credentials extraction), `WifiNetworkSpecifier` (`removeCapability(NET_CAPABILITY_INTERNET)`), and scoped `ConnectivityManager.bindProcessToNetwork(network)` with guaranteed release in `onLost` / `teardown`.

### Task 8: Windows C++/WinRT Direct Fabric Static Library (`windows/direct/`) + Channel Registration
**Files:**
- Create: `windows/direct/CMakeLists.txt` (`cppwinrt`, `/EHsc`, `cxx_std_17`, links `wlanapi.lib`, `windowsapp.lib`)
- Create: `windows/direct/daphq_direct_win.h` & `windows/direct/daphq_direct_win.cpp`
- Create: `windows/runner/direct_fabric_plugin.h` & `windows/runner/direct_fabric_plugin.cpp`
- Modify: `windows/CMakeLists.txt` & `windows/runner/CMakeLists.txt` & `windows/runner/flutter_window.cpp`
- [ ] Implement C ABI static lib wrapping `BluetoothLEAdvertisementPublisher` (`ManufacturerData 0x4451`, without touching `LocalName`/`Flags`), `BluetoothLEAdvertisementWatcher`, `GattServiceProvider`, `WiFiDirectAdvertisementPublisher` (`LegacySettings`), `WiFiDirectConnectionListener` (`GetConnectionEndpointPairs`), and `WlanSaveTemporaryProfile` / `WlanSetProfile(WLAN_PROFILE_USER)` + `WlanConnect` + interface IP lookup + clean disconnect/cleanup.
- [ ] Register `com.omarafifi.daphq/direct_fabric` `MethodChannel` + `EventChannel` in `flutter_window.cpp` cleanly (unregistering on destroy).

---

## Stage 3: Integration into `DiscoveryService`, `TransferCubit`, `HomePage`, `OrbitalRadar`, `AuthDialog` & QR UI

### Task 9: Wire Fabric, Reverse-Connect, Trust Check, & Smart Mode into `TransferCubit` & `TransferState`
**Files:**
- Modify: `lib/services/discovery_service.dart` (emit `peerId`/`fingerprint`/`caps` in discovery JSON)
- Modify: `lib/cubits/transfer_state.dart` (add `unifiedPeers`, `transportPreference`, `trustedPeers`, `isDirectLinkConnecting`, `directLinkStatus`)
- Modify: `lib/cubits/transfer_cubit.dart` (integrate `DeviceIdentityService`, `TrustedDevicesService`, `PeerRegistry`, `DirectNativeBridge`, `SmartLinkEvaluator`, TLS + Multi-Stream + SAS pinning; preserve ALL existing foreground service, notification IDs, permission checks, and delays)
- Modify: `lib/main.dart` (additively request runtime Nearby/BLE permissions only when appropriate without disrupting existing startup flow)

### Task 10: UI Upgrades (`OrbitalRadar`, `AuthDialog`, `QrPairingDialog`, `TrustedDevicesDialog`, Mode Toggle)
**Files:**
- Modify: `lib/views/widgets/common/orbital_radar.dart` (show LAN ⚡ / BLE Direct 📡 / Trusted 🛡️ indicators concisely)
- Modify: `lib/views/widgets/receiver/auth_dialog.dart` (display 4-digit SAS verification badge, MITM warning badge when fingerprint mismatches, `"Trust this device"` checkbox)
- Create: `lib/views/widgets/common/qr_pairing_dialog.dart` (`QrImageView` + paste/enter `daphq://pair` link fallback + copyable pair token)
- Create: `lib/views/widgets/common/trusted_devices_dialog.dart` (manage/revoke paired devices)
- Modify: `lib/views/widgets/common/unified_dashboard.dart` & `lib/views/home_page.dart` (add sleek `Smart Auto / 5GHz Turbo` switch + QR Pair & Trusted Devices actions while preserving zero `double.infinity` and `120 FPS` `RepaintBoundary` budgets)
- Test: `test/transfer_cubit_and_ui_test.dart` (add widget & state tests for SAS `AuthDialog`, `QrPairingDialog`, `TrustedDevicesDialog`, `OrbitalRadar` multi-transport badges, zero overflows, zero `double.infinity`).

---

## Stage 4: End-to-End Verification Gate
- [ ] Run `flutter analyze` -> MUST return `No issues found!`.
- [ ] Run `flutter test --reporter expanded` -> MUST pass 100% across all unit, security, TLS, multi-stream protocol, and UI widget tests.
- [ ] Verify `ZERO double.infinity` in `lib/`.
- [ ] Verify native build syntax (`windows/direct/` compilation + Kotlin verification without triggering release `flutter build` / `git commit`).
