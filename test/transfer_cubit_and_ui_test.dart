import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:daphq/core/app_colors.dart';
import 'package:daphq/cubits/transfer_cubit.dart';
import 'package:daphq/cubits/transfer_state.dart';
import 'package:daphq/fabric/peer_models.dart';
import 'package:daphq/models/discovery_model.dart';
import 'package:daphq/models/transfer_model.dart';
import 'package:daphq/security/trusted_devices_service.dart';
import 'package:daphq/services/history_service.dart';
import 'package:daphq/views/widgets/common/custom_snackbar.dart';
import 'package:daphq/views/widgets/common/daphq_card.dart';
import 'package:daphq/views/widgets/common/history_dialog.dart';
import 'package:daphq/views/widgets/common/info_dialog.dart';
import 'package:daphq/views/widgets/common/orbital_radar.dart';
import 'package:daphq/views/widgets/common/qr_pairing_dialog.dart';
import 'package:daphq/views/widgets/common/transfer_progress_view.dart';
import 'package:daphq/views/widgets/common/trusted_devices_dialog.dart';
import 'package:daphq/views/widgets/common/unified_dashboard.dart';
import 'package:daphq/views/widgets/receiver/auth_dialog.dart';
import 'package:daphq/views/widgets/sender/device_transfer_menu.dart';

class _FakeTransferCubit extends Cubit<TransferState> implements TransferCubit {
  bool dismissed = false;
  bool cancelledSending = false;
  bool cancelledReceiving = false;
  TransportPreference? lastPreference;
  final List<String> revokedPeerIds = [];
  String? mockPairingUri =
      'daphq://pair?v=2&id=0123456789abcdef&fp=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef&n=TestPeer&os=android&p=62004';
  bool? lastAuthAccept;
  bool lastAuthTrust = false;

  _FakeTransferCubit(super.initialState);

  void pushState(TransferState next) => emit(next);

  @override
  void dismissProgress() {
    dismissed = true;
  }

  @override
  void cancelSending({String? reason}) {
    cancelledSending = true;
  }

  @override
  void cancelReceiving({String? reason}) {
    cancelledReceiving = true;
  }

  @override
  Future<void> setTransportPreference(TransportPreference preference) async {
    lastPreference = preference;
    emit(state.copyWith(transportPreference: preference));
  }

  @override
  Future<void> revokeTrustedDevice(String peerId) async {
    revokedPeerIds.add(peerId);
    emit(
      state.copyWith(
        trustedDevices: state.trustedDevices
            .where((d) => d.peerId != peerId)
            .toList(),
      ),
    );
  }

  @override
  Future<PairingToken?> trustPeerFromQr(String rawUri) async {
    final token = PairingQrCodec.decode(rawUri);
    if (token != null) {
      emit(
        state.copyWith(
          trustedDevices: [
            ...state.trustedDevices,
            TrustedDevice(
              peerId: token.peerId,
              certFingerprint: token.fingerprint,
              displayName: token.name,
              platform: token.platform.name,
              trustedAt: 1,
              lastSeen: 1,
            ),
          ],
        ),
      );
    }
    return token;
  }

  @override
  Future<String?> buildLocalPairingUri({String? lanIpOverride}) async =>
      mockPairingUri;

  @override
  Future<void> resolveAuth(bool accept, {bool trustPeer = false}) async {
    lastAuthAccept = accept;
    lastAuthTrust = trustPeer;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _wrapWithApp({
  required TransferCubit cubit,
  required Widget child,
  Size designSize = const Size(360, 690),
}) {
  return ScreenUtilInit(
    key: UniqueKey(),
    designSize: designSize,
    minTextAdapt: true,
    splitScreenMode: true,
    rebuildFactor: RebuildFactors.always,
    builder: (context, _) {
      return BlocProvider<TransferCubit>.value(
        value: cubit,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(16), child: child),
            ),
          ),
        ),
      );
    },
  );
}

void main() {
  group('DiscoveryModel equality & hashing', () {
    test('equals only when both ip and name match', () {
      final a = DiscoveryModel(
        ip: '192.168.1.20',
        name: 'Laptop',
        lastSeen: DateTime(2026, 1, 1),
      );
      final sameDeviceUpdatedTime = DiscoveryModel(
        ip: '192.168.1.20',
        name: 'Laptop',
        lastSeen: DateTime(2026, 1, 2),
      );
      final renamedDeviceSameIp = DiscoveryModel(
        ip: '192.168.1.20',
        name: 'Workstation',
        lastSeen: DateTime(2026, 1, 2),
      );
      final otherIpSameName = DiscoveryModel(
        ip: '192.168.1.21',
        name: 'Laptop',
        lastSeen: DateTime(2026, 1, 1),
      );

      expect(a, equals(sameDeviceUpdatedTime));
      expect(a.hashCode, equals(sameDeviceUpdatedTime.hashCode));
      expect(a, isNot(equals(renamedDeviceSameIp)));
      expect(a, isNot(equals(otherIpSameName)));
    });
  });

  group('TransferModel & TransferState phase handling', () {
    test('defaults to TransferPhase.idle and preserves phase updates', () {
      final model = TransferModel();
      expect(model.phase, TransferPhase.idle);

      model.phase = TransferPhase.finalizing;
      model.status = 'Finalizing...';
      expect(model.phase, TransferPhase.finalizing);
      expect(model.status, 'Finalizing...');
    });

    test('AuthRequest formats MB and GB accurately', () {
      final mb = AuthRequest(
        senderIp: '10.0.0.2',
        senderName: 'Phone',
        fileCount: 3,
        totalSizeMB: 42.5,
      );
      final gb = AuthRequest(
        senderIp: '10.0.0.2',
        senderName: 'Phone',
        fileCount: 3,
        totalSizeMB: 2048.0,
      );

      expect(mb.formattedSize, '42.5 MB');
      expect(gb.formattedSize, '2.00 GB');
    });
  });

  group('UI widgets zero double.infinity & TransferPhase rendering', () {
    testWidgets('DaphqCard renders cleanly on mobile and desktop viewports', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final cubit = _FakeTransferCubit(TransferState(model: TransferModel()));
      addTearDown(cubit.close);

      await tester.pumpWidget(
        _wrapWithApp(
          cubit: cubit,
          child: const Column(
            children: [
              DaphqCard(isDesktop: true, child: Text('Desktop Card')),
              SizedBox(height: 12),
              DaphqCard(isDesktop: false, child: Text('Mobile Card')),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Desktop Card'), findsOneWidget);
      expect(find.text('Mobile Card'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'TransferProgressView drives colors and actions from TransferPhase on mobile & desktop',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(412, 915));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final cubit = _FakeTransferCubit(
          TransferState(
            showProgressView: true,
            isTransferring: true,
            model: TransferModel(
              phase: TransferPhase.analyzing,
              status: 'Scanning files...',
              analyzeCount: 42,
            ),
          ),
        );
        addTearDown(cubit.close);

        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: const TransferProgressView(isDesktop: false),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Scanning files...'), findsOneWidget);
        expect(find.text('42 files'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Transition to TransferPhase.finalizing — still active, primary color, no Done yet.
        cubit.pushState(
          TransferState(
            showProgressView: true,
            isReceivingActive: true,
            model: TransferModel(
              phase: TransferPhase.finalizing,
              status: 'Finalizing...',
              progress: 1.0,
              totalSize: 10.0,
              transferred: 10.0,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        final finalizingText = tester.widget<Text>(find.text('Finalizing...'));
        expect(finalizingText.style?.color, AppColors.primary);
        expect(find.text('Done'), findsNothing);
        expect(find.text('Dismiss'), findsNothing);
        expect(tester.takeException(), isNull);

        // Transition to TransferPhase.failed even with a custom message lacking keywords.
        cubit.pushState(
          TransferState(
            showProgressView: true,
            isTransferring: false,
            isReceivingActive: false,
            model: TransferModel(
              phase: TransferPhase.failed,
              status: 'Peer closed socket prematurely',
            ),
          ),
        );
        await tester.pumpAndSettle();

        final failedText = tester.widget<Text>(
          find.text('Peer closed socket prematurely'),
        );
        expect(failedText.style?.color, AppColors.danger);
        expect(find.text('Dismiss'), findsOneWidget);

        cubit.pushState(
          TransferState(
            showProgressView: true,
            isTransferring: false,
            isReceivingActive: false,
            model: TransferModel(
              phase: TransferPhase.failed,
              status: 'Connection lost',
              progress: 0.4,
              totalSize: 10.0,
              fileName: 'video.mp4',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Transfer Failed'), findsOneWidget);
        expect(find.text('Transfer Cancelled'), findsNothing);

        // Transition to TransferPhase.done on desktop viewport and verify Done action.
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: const TransferProgressView(isDesktop: true),
          ),
        );
        cubit.pushState(
          TransferState(
            showProgressView: true,
            isTransferring: false,
            isReceivingActive: false,
            model: TransferModel(
              phase: TransferPhase.done,
              status: 'Transfer Complete',
              progress: 1.0,
              totalSize: 10.0,
              transferred: 10.0,
              avgSpeed: '25.0',
              totalTime: '0.4',
            ),
          ),
        );
        await tester.pumpAndSettle();

        final doneText = tester.widget<Text>(
          find.text('Transfer Complete').first,
        );
        expect(doneText.style?.color, AppColors.success);
        expect(find.text('Done'), findsOneWidget);

        await tester.tap(find.text('Done'));
        await tester.pump();
        expect(cubit.dismissed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Zero-Router Fabric & Security UI', () {
    testWidgets(
      'AuthDialog shows TLS badge, SAS PIN, Trust toggle on normal prompt, and warns on MITM mismatch',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 690));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final cubit = _FakeTransferCubit(TransferState(model: TransferModel()));
        addTearDown(cubit.close);

        bool? decision;
        bool trustSelected = false;

        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: Builder(
              builder: (context) => Column(
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      trustSelected = false;
                      decision = await showAuthDialog(
                        context: context,
                        senderIp: '192.168.1.44',
                        senderName: 'Pixel 9 Pro',
                        fileCount: 2,
                        formattedSize: '12.4 MB',
                        sasCode: '4829',
                        isTls: true,
                        canTrustPeer: true,
                        onTrustChanged: (val) => trustSelected = val,
                      );
                    },
                    child: const Text('Open Normal Auth'),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      await showAuthDialog(
                        context: context,
                        senderIp: '192.168.1.44',
                        senderName: 'Unknown Host',
                        fileCount: 1,
                        formattedSize: '1.0 MB',
                        sasCode: '9910',
                        isTls: true,
                        isFingerprintMismatch: true,
                        canTrustPeer: true,
                      );
                    },
                    child: const Text('Open Mismatch Auth'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        // 1. Normal TLS prompt with SAS PIN + Trust checkbox (mobile 360x690)
        await tester.tap(find.text('Open Normal Auth'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('TLS 1.3 Encrypted'), findsOneWidget);
        expect(find.text('4829'), findsOneWidget);
        expect(
          find.text('Trust this device for future auto-accept'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(
          find.text('Trust this device for future auto-accept'),
        );
        await tester.tap(find.text('Trust this device for future auto-accept'));
        await tester.pump();
        expect(trustSelected, isTrue);

        await tester.ensureVisible(find.text('Accept'));
        await tester.tap(find.text('Accept'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(decision, isTrue);

        // 2. MITM fingerprint mismatch prompt on desktop viewport (1280x800)
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        await tester.pump();
        await tester.tap(find.text('Open Mismatch Auth'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.textContaining('Device key changed since last trusted session'),
          findsOneWidget,
        );
        expect(
          find.text('Trust this device for future auto-accept'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'QrPairingDialog renders QrImageView, validates invalid tokens, and pairs valid token',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() async {
          CustomSnackBar.hide();
          await tester.binding.setSurfaceSize(null);
        });

        final cubit = _FakeTransferCubit(TransferState(model: TransferModel()));
        addTearDown(cubit.close);

        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () =>
                    QrPairingDialog.show(context, isDesktop: true),
                child: const Text('Open QR'),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('Open QR'));
        await tester.pumpAndSettle();

        expect(find.byType(QrImageView), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Empty submission feedback
        await tester.ensureVisible(find.text('Pair & Trust Device'));
        await tester.tap(find.text('Pair & Trust Device'));
        await tester.pump();
        expect(
          find.text('Paste a valid daphq://pair token first.'),
          findsOneWidget,
        );

        // Invalid token feedback
        await tester.enterText(find.byType(TextField), 'not-a-valid-uri');
        await tester.ensureVisible(find.text('Pair & Trust Device'));
        await tester.tap(find.text('Pair & Trust Device'));
        await tester.pump();
        expect(find.text('Invalid pairing token format.'), findsOneWidget);

        // Valid token pairing
        final validUri = PairingQrCodec.encode(
          const PairingToken(
            peerId: 'fedcba9876543210',
            fingerprint:
                'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
            name: 'Galaxy S25',
            platform: PeerPlatform.android,
          ),
        );
        await tester.enterText(find.byType(TextField), validUri);
        await tester.ensureVisible(find.text('Pair & Trust Device'));
        await tester.tap(find.text('Pair & Trust Device'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));

        expect(cubit.state.trustedDevices, hasLength(1));
        expect(cubit.state.trustedDevices.first.displayName, 'Galaxy S25');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'TrustedDevicesDialog displays devices and triggers revokeTrustedDevice',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final cubit = _FakeTransferCubit(
          TransferState(
            model: TransferModel(),
            trustedDevices: const [
              TrustedDevice(
                peerId: 'aaaa1111bbbb2222',
                certFingerprint:
                    '1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff',
                displayName: 'Studio Desktop',
                platform: 'windows',
                trustedAt: 100,
                lastSeen: 100,
              ),
            ],
          ),
        );
        addTearDown(cubit.close);

        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: const TrustedDevicesDialog(isDesktop: true),
          ),
        );
        await tester.pump();

        expect(find.text('Studio Desktop'), findsOneWidget);
        expect(find.text('Revoke'), findsOneWidget);

        await tester.tap(find.text('Revoke'));
        await tester.pump();

        expect(cubit.revokedPeerIds, ['aaaa1111bbbb2222']);
        expect(find.text('No trusted devices yet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'OrbitalRadar shows BLE, 5G+LAN, and Trusted badge cleanly without overflow',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 690));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        const blePeer = UnifiedPeer(
          peerId: '0123456789abcdef',
          name: 'Phone BLE',
          platform: PeerPlatform.android,
          bleAddress: 'AA:BB:CC:DD:EE:01',
          isTrusted: true,
        );
        const dualPeer = UnifiedPeer(
          peerId: 'fedcba9876543210',
          name: 'Workstation',
          platform: PeerPlatform.windows,
          lanIp: '192.168.1.50',
          bleAddress: 'AA:BB:CC:DD:EE:02',
          isTrusted: false,
        );

        final cubit = _FakeTransferCubit(
          TransferState(
            model: TransferModel(),
            isReceiving: true,
            unifiedPeers: const [blePeer, dualPeer],
            discoveredDevices: [
              blePeer.toDiscoveryModel(),
              dualPeer.toDiscoveryModel(),
            ],
          ),
        );
        addTearDown(cubit.close);

        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: const OrbitalRadar(isDesktop: false, size: 320),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('BLE'), findsOneWidget);
        expect(find.text('5G+LAN'), findsOneWidget);
        expect(find.byIcon(Icons.verified_user_rounded), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'UnifiedDashboard renders Fabric controls, switches TransportPreference, and fits mobile & desktop viewports',
      (tester) async {
        final cubit = _FakeTransferCubit(
          TransferState(
            model: TransferModel(),
            isReceiving: true,
            deviceName: 'Test-PC',
          ),
        );
        addTearDown(cubit.close);

        // Mobile viewport (360x690)
        await tester.binding.setSurfaceSize(const Size(360, 690));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: const UnifiedDashboard(isDesktop: false),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Smart Auto'), findsOneWidget);
        expect(find.text('5GHz Turbo'), findsOneWidget);
        expect(find.text('LAN'), findsOneWidget);
        expect(find.text('QR Pair'), findsOneWidget);
        expect(find.text('Trusted (0)'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('5GHz Turbo'));
        await tester.pump(const Duration(milliseconds: 50));
        expect(cubit.lastPreference, TransportPreference.directTurbo);

        // Desktop viewport (1280x800)
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: const UnifiedDashboard(isDesktop: true),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'DeviceTransferMenu renders 1-line and 2-line filenames without RenderFlex overflow on desktop & mobile',
      (tester) async {
        const longPath =
            r'C:\Users\Omar\Documents\Very_Long_Project_Archive_2026_11_13_Final_Build_Release_Candidate_With_Extra_Metadata.tar.gz';
        const shortPath = r'C:\Users\Omar\Desktop\clip.mp4';
        const folderPath = r'C:\Users\Omar\Documents\MediaBundle';

        final cubit = _FakeTransferCubit(
          TransferState(
            model: TransferModel(),
            selectedPaths: const [shortPath, longPath, folderPath],
            selectedPathsIsDir: const {folderPath: true},
          ),
        );
        addTearDown(cubit.close);

        // Windows desktop viewport (1100x700) — reproduces the reported 8px overflow regression
        await tester.binding.setSurfaceSize(const Size(1100, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => DeviceTransferMenu.show(
                  context,
                  '192.168.1.55',
                  'Windows-Workstation',
                  true,
                ),
                child: const Text('Open Menu'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open Menu'));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('clip.mp4'), findsOneWidget);
        expect(find.text('MediaBundle'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Tight desktop viewport (720x420)
        await tester.binding.setSurfaceSize(const Size(720, 420));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);

        // Mobile bottom sheet viewport (360x690)
        await tester.binding.setSurfaceSize(const Size(360, 690));
        await tester.pumpWidget(
          _wrapWithApp(
            cubit: cubit,
            child: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => DeviceTransferMenu.show(
                  context,
                  '192.168.1.55',
                  'Pixel 9',
                  false,
                ),
                child: const Text('Open Sheet'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open Sheet'));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('clip.mp4'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'HistoryDialog renders multi-line entries without overflow on desktop & mobile',
      (tester) async {
        final tempDir = await tester.runAsync(
          () => Directory.systemTemp.createTemp('daphq_hist_ui_test_'),
        );
        HistoryService.directoryProvider = () async => tempDir!;
        addTearDown(() async {
          HistoryService.directoryProvider = null;
          await tester.runAsync(() async {
            try {
              await tempDir?.delete(recursive: true);
            } catch (_) {}
          });
        });

        await tester.runAsync(
          () => HistoryService.addEntries([
            HistoryEntryInput(
              fileName:
                  'Very_Long_History_Filename_2026_With_Many_Words_And_Extensions_Final_Archive_Backup.zip',
              fileSizeMB: 2048.5,
              direction: 'send',
              status: 'success',
              localPath: r'C:\Users\Omar\Desktop\backup.zip',
            ),
            HistoryEntryInput(
              fileName: 'failed_transfer_with_error_message_details.tar',
              fileSizeMB: 55.2,
              direction: 'receive',
              status: 'failed',
            ),
          ]),
        );

        final cubit = _FakeTransferCubit(TransferState(model: TransferModel()));
        addTearDown(cubit.close);

        // Windows desktop (1100x700)
        await tester.binding.setSurfaceSize(const Size(1100, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          _wrapWithApp(cubit: cubit, child: const HistoryDialog(isDesktop: true)),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Transfer History'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Mobile viewport (360x690)
        await tester.binding.setSurfaceSize(const Size(360, 690));
        await tester.pumpWidget(
          _wrapWithApp(cubit: cubit, child: const HistoryDialog(isDesktop: false)),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Transfer History'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'InfoDialog renders cleanly on small mobile and desktop viewports without overflow',
      (tester) async {
        final cubit = _FakeTransferCubit(TransferState(model: TransferModel()));
        addTearDown(cubit.close);

        for (final size in const [
          Size(320, 540),
          Size(360, 690),
          Size(1100, 700),
        ]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            _wrapWithApp(cubit: cubit, child: const InfoDialog()),
          );
          await tester.pump(const Duration(milliseconds: 50));
          expect(
            tester.takeException(),
            isNull,
            reason: 'InfoDialog overflowed at $size',
          );
        }
        await tester.binding.setSurfaceSize(null);
      },
    );
  });
}
