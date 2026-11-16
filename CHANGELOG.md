# Changelog

Complete version history of **Daphq**, covering every release from **v1.0.0** through **v3.0.0**, verified directly against the codebase changes in each release.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses [Semantic Versioning](https://semver.org/).

---

## [3.0.0] (`3.0.0+10`)

Major architectural upgrade over `v2.3.1`: introduces the **Zero-Touch 5GHz Direct Wi-Fi & BLE Fabric**, multi-stream **80–90+ MB/s** raw TCP transfers, hardware-backed device identity & trust, typed state lifecycle, HiDPI visuals, redesigned user-focused documentation/website, and 118 automated tests.

### Quick Comparison: v2.3.1 vs. v3.0.0

| Area | v2.3.1 | v3.0.0 |
| :--- | :--- | :--- |
| **Discovery & Linking** | UDP LAN broadcast (`62005`) + manual hotspot/IP entry | **BLE GATT + UDP discovery** (`62005` + fallbacks `42605–42607`) with zero-touch **5GHz Direct Wi-Fi** pairing |
| **5GHz Reliability** | Manual hotspot setup; repeated Android Wi-Fi pickers or 2.4GHz drops | Deterministic `(SSID, PSK)` pairing, **bidirectional 5GHz host flip**, and manual Windows Hotspot preservation |
| **Transfer Engine** | Single-stream v1 TCP (`1 MB` socket flush threshold) | **Multi-stream v2 raw TCP framing**, reverse-connect topology, zero-copy chunk slicing, and **8 MB** flush threshold |
| **Security & Trust** | Basic receiver accept prompt | **EC P-256 identity**, **SHA-256 TLS pinning** on control links, **4-digit SAS codes**, **Trusted Devices**, and path-traversal sanitization |
| **State & Desktop IPC** | String-based status matching & polled `.tmp`/`.json` queue | Typed **`TransferPhase`** state machine, session cancellation tokens, OS `Directory.watch` IPC, and **118 tests** |
| **Branding & Toolchain** | Startup icons, Gradle/AGP v8, legacy website/README | **8-frame HiDPI `.ico`**, **Gradle 9.3.1 / AGP 9.1.0 / Kotlin 2.4.0**, plain-language errors, and redesigned **README** & **Website** |

### Added

* **Zero-Touch 5GHz Direct Wi-Fi & BLE Fabric (`lib/fabric/`, `windows/direct/`, `DirectFabricHandler.kt`):**
  * **Android Native Radio Bridge (`DirectFabricHandler.kt`):** Added out-of-band BLE GATT advertising/scanning & control characteristics, deterministic 5GHz Wi-Fi Direct Group Owner negotiation, automatic `WifiNetworkSpecifier` linking, client frequency measurement when SoftAP reports `0`, and direct shortcut routing (`nextStepAfterChannels`) when `allow24GhzFallback` is disabled.
  * **Windows Native Radio Bridge (`windows/direct/daphq_direct_win.cpp`, `direct_fabric_plugin.cpp`):** Added native WinRT `NetworkOperatorTetheringManager` SoftAP hosting, Wi-Fi Direct support, WLAN performance mode toggling (`SetWlanInterfacePerfMode`), and active-transfer power locks.
  * **Smart Link Evaluator (`SmartLinkEvaluator`, `PeerRegistry`, `BleBeaconCodec`):** Encodes compact 22-byte BLE manufacturer payloads, deduplicates peers across LAN + BLE into `UnifiedPeer` models, and plans Direct 5GHz, manual hotspot reuse, reverse-connect, or transparent LAN fallback routes.
  * **Bidirectional 5GHz Host Flip:** When a device rejects or fails 5GHz Direct group creation (`direct5gUnsupported`), Daphq caches the peer capability (`_peersLackingDirect5gHost`), updates local capability broadcasts (`_applyLocalCapabilities`), and flips 5GHz SoftAP hosting to the capable side automatically.
* **v2 Multi-Stream Transfer Protocol (`v2_protocol_framing.dart`, `SenderController`, `ReceiverController`):**
  * Concurrent worker sockets (`SocketOption.tcpNoDelay`) using raw TCP for bulk payloads while reserving pinned TLS for control handshakes (`startHostAndWait`, `joinHost`) and reverse-connect coordination.
  * Non-ephemeral fallback ports outside Windows Hyper-V/WSL NAT ranges (`transferFallbackPorts: [42604, 42608]`, `discoveryPorts: [62005, 42605, 42606, 42607]`) propagated cleanly into BLE beacons and host responses.
  * Raised `socketFlushThresholdBytes` from `1 MB` to **`8 MB`** (`8 * 1024 * 1024`) and emitted `reportBytesSent` immediately upon socket writes so Windows and Android speeds (**80–90+ MB/s** on 5GHz) and progress bars stay synchronized.
* **Device Identity, Control TLS & Trusted Devices (`lib/security/`, `TrustedDevicesDialog`):**
  * **EC P-256 Identity (`DeviceIdentityService`):** Generates and persists per-device EC P-256 keys/certificates and computes SHA-256 DER fingerprints.
  * **Short Authentication Strings (`computeSasCode`):** Derives a symmetric, order-independent 4-digit SAS verification code (`daphq-sas-v2`) shown during authorization.
  * **Trusted Devices Store (`TrustedDevicesService`, `TrustedDevicesDialog`):** Serialized trust store allowing users to inspect/revoke trusted peers and immediately aborting transfers (without falling back) on MITM `fingerprintMismatch`.
* **HiDPI Brand Refresh:**
  * Updated circular DQ logo (`assets/logo.png`), crisp Android adaptive monochrome icons across all densities (`mdpi` through `xxxhdpi`), and an **8-frame HiDPI `app_icon.ico`** with dynamic Windows DPI loading (`win32_window.cpp`, `flutter_window.cpp`).
* **Automated Test Suite (`test/` — 8 suites, 118 passing tests):**
  * Added full coverage across `receiver_security_test.dart`, `security_and_fabric_test.dart`, `transfer_protocol_test.dart`, `transfer_cubit_fabric_test.dart`, `transfer_cubit_and_ui_test.dart`, `desktop_integration_service_test.dart`, `history_service_test.dart`, and `update_service_test.dart`.

### Changed & Improved

* **Zero-Prompt Reconnects on Consecutive 5GHz Transfers:**
  * Derived deterministic 12-character WPA2 passphrases (`DeriveStableDirectPsk`) tied to the host's stable tag so Android keeps honoring its one-time first-use `WifiNetworkSpecifier` approval across subsequent sessions instead of re-prompting.
  * Added `TetheringOperationalState::InTransition` wait loops and transient `StartTetheringAsync` retry in `daphq_direct_win.cpp`, skipped redundant `ConfigureAccessPointAsync` writes when SSID/PSK/band already match, and skipped restoring temporary `DIRECT-DQ-` configs during session teardown.
  * Added `_sendLanDirectControlWithRetry` (up to 3 attempts at `500ms` on transient `SocketException`/`TimeoutException`) for `joinHost` and `startHostAndWait` while Android finishes re-associating with the router Wi-Fi after an earlier Direct transfer.
* **Manual Windows Mobile Hotspot Preservation:**
  * Detects when Windows Mobile Hotspot is already active manually (non-`DIRECT-DQ-` SSID), leaves its custom name and password intact, routes transfers through it directly, and leaves it running after completion.
* **Typed Transfer State Machine (`TransferPhase`):**
  * Replaced string-matched status comparisons with strongly typed `TransferPhase` lifecycles and `_sendSessionToken` isolation guards, keeping completed transfer cards intact when background receiver restarts reset to idle, and enabling instant cancellation across active workers and foreground teardown (`waitForPendingRejection`).
* **Cleaner UI, Friendly Diagnostics & Performance:**
  * Removed distracting protocol clutter badges (`LAN`, `BLE`, `5G+LAN`) from the Orbital Radar (`orbital_radar.dart`), translated cryptic socket errors into everyday user-friendly guidance, and throttled Android foreground progress notifications (`1500ms`).
  * Isolated high-frequency animations inside `RepaintBoundary`, gated idle tickers, eliminated `double.infinity` bounds across layouts, and fixed desktop pointer/scroll deadlocks after native file picker modals.
  * Switched desktop Share/Explorer queue IPC (`DesktopIntegrationService`) from polling to event-driven OS `Directory.watch`.
  * Upgraded toolchain & packages to **Gradle 9.3.1**, **AGP 9.1.0**, **Kotlin 2.4.0**, **Dart `^3.11.4`**, `file_picker ^13.3.3`, `flutter_markdown_plus ^1.0.12`, and `basic_utils ^5.8.2`.
  * Cleaned up `build_and_export.ps1` (removed unused `.sha256` sidecar output and commented AAB stubs), removed unused Dart files (`core.dart`, `section_title.dart`, `status_text.dart`), and completely redesigned `README.md`, `CHANGELOG.md`, and the `docs/` website for everyday users (including the restored & upgraded interactive constellation canvas `network-bg.js` with `prefers-reduced-motion` and pause toggle support).

### Fixed

* **Receiver Security & Atomic Disk Finalization (`ReceiverController`):** Blocked `..` traversal, absolute POSIX/Windows drive paths, empty paths, and Windows-reserved filenames (`safeRelativePath`); wrote incoming transfers to `.daphq-partial` temporary files before atomic final rename; deduplicated colliding relative paths within a single batch (`SenderController`); and preserved existing files via automatic safe renaming (`photo (1).jpg`).
* **Service & Updater Reliability:** Serialized `HistoryService` and `TrustedDevicesService` writes to prevent concurrent write loss; freed Win32 mutex name buffers properly (`DesktopIntegrationService`); isolated updater downloads (`UpdateService`) and awaited size + `.sha256` digest verification when sibling digest assets are published; surfaced share-intent copy failures cleanly (`NativeShareService`).
* **Android Release Build R8 Crash:** Added `com.omarafifi.daphq.**` keep rules in `android/app/proguard-rules.pro` fixing `ArrayIndexOutOfBoundsException` in `:app:minifyReleaseWithR8`.

---

## [2.3.1] (`2.3.1+9`)

### Fixed
* Removed startup `regsvr32 DaphqShellExt.dll` context-menu registration from `lib/main.dart`, eliminating unnecessary Windows system prompts and Explorer DLL lock conflicts during updates and app restarts.

---

## [2.3.0] (`2.3.0+8`)

### Added
* **Native Android Share & Folder Handlers (`NativeShareHandler.kt`, `NativeFolderHandler.kt`, `NativeShareService`):** Replaced the third-party `share_handler` plugin with dedicated native Kotlin handlers (`MethodChannel`) for system Share intents and modern Android SAF/FileProvider directory opening.
* **Persistent Receive Directory:** Saved the user's custom receive folder path across app restarts instead of resetting to the default Downloads folder.
* **Background-to-Foreground Auth Bring-Up:** Added Windows/mobile bring-to-foreground support when an incoming authorization request arrives while minimized or behind other windows.
* **Batch Scanning Overlay & `locatingFolder` State:** Added chunked file discovery checks and a loading state/overlay when inspecting large folders so the interface never freezes.
* **Interactive Showcase Assets:** Recorded and added `Demo.gif` across `README.md` and the `docs/` website.

### Changed & Fixed
* **Non-Blocking Receiver Accept Loop (`ReceiverController`):** Moved per-connection handling into an asynchronous closure inside the listening `ServerSocket` loop so handling one peer never blocks accepting or rejecting subsequent requests.
* **Safe Startup Cache Cleanup:** Cleared stale temporary app cache on startup only when the app was **not** launched via an incoming Share intent, preventing shared staged files from being deleted mid-launch.
* Temporarily added `regsvr32` Shell Extension registration on Windows startup (removed cleanly in `v2.3.1`).

---

## [2.2.0] (`2.2.0+5`)

### Added
* **Direct 5GHz Speed Tip (`DirectTransferTipDialog`):** Added an educational dialog and speed recommendation prompt guiding users toward 5GHz Wi-Fi / Hotspot connections.
* **Website OS-Aware Primary CTAs:** Updated `docs/js/main.js` so Windows visitors see **Download for Windows** and Android visitors see **Download for Android** promoted cleanly.

### Changed & Improved
* **Zero-Delay Accept Handshake (`ReceiverController`):** Started pre-fetching free storage space asynchronously (`1500ms` timeout) *in the background* while the authorization dialog is on screen instead of blocking after the user taps Accept, immediately transitioning UI status to `"Connecting & Starting..."`.
* **Responsive Batch Enumeration (`SenderController`, `UnifiedAddButton`):** Switched folder checks to async loading states and emitted `analyzeCount` progress updates every **50 files** instead of waiting >2 seconds before showing feedback.
* **Socket Buffering & Radar Polish (`AppConstants`, `OrbitalRadar`, `TransferProgressView`):** Tuned socket/UI updates and refined the orbital radar and transfer progress views.

---

## [2.1.0] (`2.1.0+3`)

### Added
* **Unified Dashboard & Orbital Radar (`UnifiedDashboard`, `OrbitalRadar`, `AnimatedBackground`):** Replaced separate Sender/Receiver/Devices panels with a single unified command dashboard centered around an animated Orbital Radar and constellation backdrop (`desktopScale` responsive scaling).
* **Persistent Transfer History (`HistoryService`, `HistoryDialog`):** Logged past sends and receives locally with status outcomes, expanded history retention limit, and tap-to-open access for received files.
* **In-App GitHub Updater (`UpdateService`, `UpdateDialog`):** Enhanced release checking and download/install dialogs, automatically skipping updates that lack an asset matching the current OS.
* **Rich File Icons (`FileUtils`):** Added typed file icons across staging menus and transfer items.
* **Active Receive Cancellation:** Enabled cancelling in-progress incoming file transfers cleanly from the receiver side (`_isActiveTransferCancelled`).

### Changed & Fixed
* **Small-File Memory Buffer Optimization (`ReceiverController`):** Buffered files **`<= 512 KB`** in memory (`BytesBuilder(copy: false)`) before flushing while streaming larger files via `IOSink`, plus cached `createdDirs` directory checks and batched `closeFutures` to reduce small-file disk syscalls dramatically.
* **Native Windows Lifecycle (`windows/`):** Added local single-instance mutex and clean `ExitProcess` handling, cached `isDirectory` results during staging, removed staggered list-entrance animations, reduced heavy card shadows, and broadened socket failure checks.

---

## [2.0.0] (`2.0.0+2`)

### Added
* **Automatic Network Discovery Engine (`DiscoveryService`, `DiscoveryModel`, `DiscoveryStatusBanner`):** Added UDP local network discovery on port `62005` (`3s` broadcast interval), `OFFLINE` bye signals, IP caching, connectivity-aware auto-recovery watchdog, `noConnection` status tracking, and Windows ICS/Hotspot port-conflict troubleshooting guidance.
* **Whole-Folder Sync & Smart Batch Menus (`UnifiedAddButton`, `DeviceTransferMenu`):** Added recursive async directory traversal preserving exact subfolder trees, batch multi-file staging with selection banners, and platform-specific Smart Add menus (Files, Folders, Photos, Videos).
* **System-Wide File Sharing:** Integrated mobile sharing via `share_handler`, Windows single-instance launch deduplication (`DesktopIntegrationService`), drag/drop/file-argument launch queuing, and `"Open Received Folder"` (`Process.run` on desktop, SAF/FileProvider on Android).
* **Real-Time Analytics & Guardrails:** Added total batch byte tracking, live ETA estimates, `1.0` completion progress clamping, peer device names on prompts/status updates, pre-transfer disk-space validation (`storage_space`), filename sanitization, and `15s` active socket transfer timeout (`AppConstants.transferTimeoutSeconds`).
* **Project Website Launch (`docs/`):** Published the official GitHub Pages site with dynamic GitHub Releases integration, `network-bg.js` interactive background, interface showcase screenshots, and speed comparison section.

### Changed & Fixed
* Decoupled sending and receiving states cleanly inside `TransferCubit` and reorganized widgets into `common/`, `sender/`, and `receiver/` modules (`InfoDialog` replaced static instructions cards; `1 MB` `socketFlushThresholdBytes` and `1 MB` JSON header size cap).
* Locked mobile orientation to portrait, tailored Android storage/notification permissions by SDK version, prevented crashes on malformed UDP discovery packets, and ensured all file sinks and sockets close reliably inside `finally` blocks.

---

## [1.0.0] (`1.0.0+1`)

Initial public release establishing Daphq's cross-platform Windows & Android architecture and bare-metal TCP streaming engine *(including initial prototype, pre-1.0 `beta-1.1`/`v1.1`/`1.1-v` milestones, and final `v1.0.0` release)*.

### Added
* **Raw TCP Streaming Core (`SenderController`, `ReceiverController`):** Split the initial `TransferController` prototype into dedicated `SenderController` and `ReceiverController` classes communicating over port `62004` with `SocketOption.tcpNoDelay` (disabling Nagle's algorithm) and `2 MB` buffered socket flushing, bypassing HTTP overhead.
* **Zero-Copy Receiver Slicing & Collision Safety:** Used `Uint8List.sublistView` boundary slicing for incoming binary streams, capped JSON metadata headers at `1 MB`, and implemented metadata handshakes with automatic duplicate file renaming.
* **Authorization, Cancellation & Error Diagnostics (`TransferCubit`, `TransferState`, `AuthDialog`):** Implemented BLoC/Cubit state management, interactive receiver accept/reject prompts before writing bytes, bidirectional transfer cancellation with remote disconnect detection, and human-readable socket error mapping.
* **Background Persistence & Desktop Support:** Added Android Foreground Service (`flutter_foreground_task`) with notification Stay-Alive controls and battery optimization/storage permission flows, plus responsive Windows desktop sizing via `window_manager` and title-bar icon integration (`Runner.rc`, `app_icon.ico`).
* **Initial In-App Update Checker & UI Kit:** Added GitHub Releases update checking (`UpdateService`, `UpdateDialog`), custom dark theme (`AppColors`), `DaphqCard`, `AnimatedPressButton`, `TransferProgressView`, global overlay `CustomSnackBar`, Android adaptive launcher icons, ProGuard & `key.properties` release signing setup, MIT `LICENSE`, and pruned unused template targets (`ios`, `linux`, `macos`, `web`) to focus natively on Android and Windows.
