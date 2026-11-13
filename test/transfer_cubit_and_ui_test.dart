import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:daphq/core/app_colors.dart';
import 'package:daphq/cubits/transfer_cubit.dart';
import 'package:daphq/cubits/transfer_state.dart';
import 'package:daphq/models/discovery_model.dart';
import 'package:daphq/models/transfer_model.dart';
import 'package:daphq/views/widgets/common/daphq_card.dart';
import 'package:daphq/views/widgets/common/transfer_progress_view.dart';

class _FakeTransferCubit extends Cubit<TransferState> implements TransferCubit {
  bool dismissed = false;
  bool cancelledSending = false;
  bool cancelledReceiving = false;

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
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _wrapWithApp({required TransferCubit cubit, required Widget child}) {
  return ScreenUtilInit(
    designSize: const Size(360, 690),
    minTextAdapt: true,
    splitScreenMode: true,
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
}
