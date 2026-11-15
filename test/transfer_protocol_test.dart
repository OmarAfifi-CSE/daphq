import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daphq/controllers/receiver_controller.dart';
import 'package:daphq/controllers/sender_controller.dart';
import 'package:daphq/controllers/v2_protocol_framing.dart';
import 'package:daphq/core/app_constants.dart';
import 'package:daphq/models/transfer_model.dart';
import 'package:daphq/security/device_identity_service.dart';

void main() {
  group('SenderController.deduplicateRelativePaths', () {
    test('deduplicates exact and case-insensitive collisions in a batch', () {
      final batch = <Map<String, dynamic>>[
        {'path': 'docs/Report.pdf', 'size': 10},
        {'path': 'docs/report.pdf', 'size': 20},
        {'path': 'docs/REPORT.PDF', 'size': 30},
        {'path': 'README.md', 'size': 5},
        {'path': 'readme.md', 'size': 6},
      ];

      SenderController.deduplicateRelativePaths(batch);

      final resolved = batch.map((e) => e['path'] as String).toList();
      expect(resolved, [
        'docs/Report.pdf',
        'docs/report (1).pdf',
        'docs/REPORT (2).PDF',
        'README.md',
        'readme (1).md',
      ]);
      // Every entry must be unique case-insensitively.
      expect(resolved.map((s) => s.toLowerCase()).toSet().length, 5);
    });
  });

  group('End-to-end TCP transfer protocol regressions', () {
    late Directory tempRoot;
    late Directory receiveDir;
    late Directory sendDir;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('daphq_proto_test_');
      receiveDir = await Directory(p.join(tempRoot.path, 'recv')).create();
      sendDir = await Directory(p.join(tempRoot.path, 'send')).create();
    });

    tearDown(() async {
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    });

    Future<({ReceiverController controller, Completer<void> stopped, int port})>
    startTestReceiver({
      required Function(TransferModel) onUpdate,
      Future<bool> Function(String, String, int, double)? onRequestAuth,
      int freeBytes = 1024 * 1024 * 1024,
    }) async {
      final controller = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();

      unawaited(
        controller.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'TestReceiver',
          port: 0,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => freeBytes,
          onUpdate: onUpdate,
          onRequestAuth: onRequestAuth ?? (_, _, _, _) async => true,
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      return (controller: controller, stopped: stopped, port: port);
    }

    test(
      'preserves large streamed file when followed by a small buffered file and trailing 0-byte file',
      () async {
        final largeBytes = Uint8List.fromList(
          List<int>.generate(600 * 1024, (i) => (i * 31) & 0xFF),
        );
        final smallBytes = utf8.encode('small trailing payload\n');

        final batchDir = await Directory(p.join(sendDir.path, 'bundle')).create();
        await File(p.join(batchDir.path, '01_large.bin')).writeAsBytes(largeBytes);
        await File(p.join(batchDir.path, '02_small.txt')).writeAsBytes(smallBytes);
        await File(p.join(batchDir.path, '03_empty.txt')).writeAsBytes(const <int>[]);

        final phases = <TransferPhase>[];
        final receiverModels = <TransferModel>[];
        final doneCompleter = Completer<void>();

        final rx = await startTestReceiver(
          onUpdate: (model) {
            phases.add(model.phase);
            receiverModels.add(model);
            if (model.phase == TransferPhase.done && !doneCompleter.isCompleted) {
              doneCompleter.complete();
            }
          },
        );

        try {
          final sender = SenderController();
          final senderPhases = <TransferPhase>[];
          await sender.sendData(
            paths: [batchDir.path],
            targetIp: '127.0.0.1',
            port: rx.port,
            targetDeviceName: 'TestReceiver',
            senderDeviceName: 'TestSender',
            onUpdate: (m) => senderPhases.add(m.phase),
          );

          await doneCompleter.future.timeout(const Duration(seconds: 5));

          final recvLarge = File(p.join(receiveDir.path, 'bundle', '01_large.bin'));
          final recvSmall = File(p.join(receiveDir.path, 'bundle', '02_small.txt'));
          final recvEmpty = File(p.join(receiveDir.path, 'bundle', '03_empty.txt'));

          expect(recvLarge.existsSync(), isTrue);
          expect(recvSmall.existsSync(), isTrue);
          expect(recvEmpty.existsSync(), isTrue);

          expect(await recvLarge.readAsBytes(), equals(largeBytes));
          expect(await recvSmall.readAsBytes(), equals(smallBytes));
          expect(await recvEmpty.readAsBytes(), isEmpty);

          expect(
            Directory(p.join(receiveDir.path, 'bundle'))
                .listSync()
                .where((e) => e.path.endsWith('.daphq-partial')),
            isEmpty,
          );
          expect(phases, containsAll([TransferPhase.finalizing, TransferPhase.done]));
          expect(senderPhases, containsAll([TransferPhase.sending, TransferPhase.finalizing, TransferPhase.done]));
        } finally {
          rx.controller.stop();
          await rx.stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test(
      'small-first transfer enforces T-001 safety and produces finite speed',
      () async {
        final tinyFile = File(p.join(sendDir.path, 'tiny.txt'));
        await tinyFile.writeAsString('hello world');

        final models = <TransferModel>[];
        final doneCompleter = Completer<void>();
        final rx = await startTestReceiver(
          onUpdate: (m) {
            models.add(m);
            if (m.phase == TransferPhase.done && !doneCompleter.isCompleted) {
              doneCompleter.complete();
            }
          },
        );

        try {
          final sender = SenderController();
          final senderModels = <TransferModel>[];
          await sender.sendData(
            paths: [tinyFile.path],
            targetIp: '127.0.0.1',
            port: rx.port,
            targetDeviceName: 'TestReceiver',
            senderDeviceName: 'TestSender',
            onUpdate: senderModels.add,
          );
          await doneCompleter.future.timeout(const Duration(seconds: 5));

          final saved = File(p.join(receiveDir.path, 'tiny.txt'));
          expect(saved.existsSync(), isTrue);
          expect(await saved.readAsString(), 'hello world');

          final rxDone = models.lastWhere((m) => m.phase == TransferPhase.done);
          final txDone = senderModels.lastWhere((m) => m.phase == TransferPhase.done);
          expect(rxDone.avgSpeed, isNot(contains('Infinity')));
          expect(rxDone.avgSpeed, isNot(contains('NaN')));
          expect(txDone.avgSpeed, isNot(contains('Infinity')));
          expect(txDone.avgSpeed, isNot(contains('NaN')));
        } finally {
          rx.controller.stop();
          await rx.stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test(
      'does not overwrite existing files on receiver when sending multiple loose files',
      () async {
        final existing = File(p.join(receiveDir.path, 'notes.txt'));
        await existing.writeAsString('DO NOT OVERWRITE');

        final dirA = await Directory(p.join(sendDir.path, 'a')).create();
        final dirB = await Directory(p.join(sendDir.path, 'b')).create();
        final fileA = File(p.join(dirA.path, 'notes.txt'));
        final fileB = File(p.join(dirB.path, 'notes.txt'));
        await fileA.writeAsString('from A');
        await fileB.writeAsString('from B');

        final doneCompleter = Completer<void>();
        final rx = await startTestReceiver(
          onUpdate: (m) {
            if (m.phase == TransferPhase.done && !doneCompleter.isCompleted) {
              doneCompleter.complete();
            }
          },
        );

        try {
          await SenderController().sendData(
            paths: [fileA.path, fileB.path],
            targetIp: '127.0.0.1',
            port: rx.port,
            targetDeviceName: 'TestReceiver',
            senderDeviceName: 'TestSender',
            onUpdate: (_) {},
          );
          await doneCompleter.future.timeout(const Duration(seconds: 5));

          expect(await existing.readAsString(), equals('DO NOT OVERWRITE'));
          final receivedContents = receiveDir
              .listSync()
              .whereType<File>()
              .map((f) => f.readAsStringSync())
              .toSet();
          expect(
            receivedContents,
            containsAll(['DO NOT OVERWRITE', 'from A', 'from B']),
          );
        } finally {
          rx.controller.stop();
          await rx.stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test(
      'rejects malicious traversal header even on a small buffered payload',
      () async {
        final failedCompleter = Completer<TransferModel>();
        final rx = await startTestReceiver(
          onUpdate: (m) {
            if (m.phase == TransferPhase.failed &&
                !failedCompleter.isCompleted) {
              failedCompleter.complete(m);
            }
          },
        );

        try {
          final client = await Socket.connect('127.0.0.1', rx.port);
          final payload = utf8.encode('pwned');
          final evilHeader = jsonEncode({
            'fileName': 'evil',
            'fileSize': payload.length,
            'senderDeviceName': 'Attacker',
            'isFolder': true,
            'files': [
              {'path': '../escaped.txt', 'size': payload.length},
            ],
          });
          client.write('$evilHeader\n');
          await client.flush();

          // Receiver rejects malicious header during handshake before ready.
          final lineCompleter = Completer<String>();
          final buf = <int>[];
          client.listen(
            (chunk) {
              buf.addAll(chunk);
              final nl = buf.indexOf(10);
              if (nl != -1 && !lineCompleter.isCompleted) {
                lineCompleter.complete(utf8.decode(buf.sublist(0, nl)));
              }
            },
            onDone: () {
              if (!lineCompleter.isCompleted) lineCompleter.complete('CLOSED');
            },
            onError: (_) {
              if (!lineCompleter.isCompleted) lineCompleter.complete('ERROR');
            },
          );
          final responseLine = await lineCompleter.future.timeout(
            const Duration(seconds: 5),
          );
          expect(responseLine, contains('REJECTED'));
          await client.close();

          final terminal = await failedCompleter.future.timeout(
            const Duration(seconds: 5),
          );
          expect(terminal.phase, TransferPhase.failed);
          expect(
            File(p.join(tempRoot.path, 'escaped.txt')).existsSync(),
            isFalse,
          );
        } finally {
          rx.controller.stop();
          await rx.stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test(
      'cleans up incomplete .daphq-partial file when sender drops mid-transfer',
      () async {
        final cancelledCompleter = Completer<void>();
        final receivingStarted = Completer<void>();
        final rx = await startTestReceiver(
          onUpdate: (m) {
            if (m.phase == TransferPhase.receiving &&
                !receivingStarted.isCompleted) {
              receivingStarted.complete();
            }
            if ((m.phase == TransferPhase.cancelled ||
                    m.phase == TransferPhase.failed) &&
                !cancelledCompleter.isCompleted) {
              cancelledCompleter.complete();
            }
          },
        );

        try {
          final client = await Socket.connect('127.0.0.1', rx.port);
          const declaredSize = 2 * 1024 * 1024; // 2MB > 512KB -> sink path
          final header = jsonEncode({
            'fileName': 'aborted.bin',
            'fileSize': declaredSize,
            'senderDeviceName': 'Peer',
            'isFolder': false,
            'files': [
              {'path': 'aborted.bin', 'size': declaredSize},
            ],
          });
          client.write('$header\n');
          await client.flush();

          final readyCompleter = Completer<void>();
          client.listen((_) {
            if (!readyCompleter.isCompleted) readyCompleter.complete();
          });
          await readyCompleter.future.timeout(const Duration(seconds: 5));

          // Send only 700 KB, then close socket prematurely.
          client.add(Uint8List(700 * 1024));
          await client.flush();
          await client.close();

          await cancelledCompleter.future.timeout(const Duration(seconds: 5));
          await Future.delayed(const Duration(milliseconds: 50));

          expect(
            File(p.join(receiveDir.path, 'aborted.bin')).existsSync(),
            isFalse,
          );
          expect(
            receiveDir
                .listSync()
                .where((e) => e.path.endsWith('.daphq-partial')),
            isEmpty,
          );
        } finally {
          rx.controller.stop();
          await rx.stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test(
      'rejects transfer with OUT_OF_SPACE when storage is insufficient',
      () async {
        final file = File(p.join(sendDir.path, 'big.bin'));
        await file.writeAsBytes(Uint8List(1024));

        final rx = await startTestReceiver(
          freeBytes: 100, // less than 1024
          onUpdate: (_) {},
        );

        try {
          await expectLater(
            SenderController().sendData(
              paths: [file.path],
              targetIp: '127.0.0.1',
              port: rx.port,
              targetDeviceName: 'TestReceiver',
              senderDeviceName: 'TestSender',
              onUpdate: (_) {},
            ),
            throwsA(
              isA<TransferSendException>().having(
                (e) => e.message,
                'message',
                contains('Insufficient storage space'),
              ),
            ),
          );
        } finally {
          rx.controller.stop();
          await rx.stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test(
      'completes all-zero-byte multi-file transfer immediately without hanging',
      () async {
        final doneCompleter = Completer<TransferModel>();
        final rx = await startTestReceiver(
          onUpdate: (m) {
            if (m.phase == TransferPhase.done && !doneCompleter.isCompleted) {
              doneCompleter.complete(m);
            }
          },
        );

        try {
          final client = await Socket.connect('127.0.0.1', rx.port);
          final header = jsonEncode({
            'fileName': 'empty_bundle',
            'fileSize': 0,
            'senderDeviceName': 'ZeroPeer',
            'isFolder': true,
            'files': [
              {'path': 'empty_bundle/a.txt', 'size': 0},
              {'path': 'empty_bundle/b.txt', 'size': 0},
            ],
          });

          final lines = <String>[];
          final buffer = <int>[];
          final doneSignal = Completer<void>();
          client.listen((chunk) {
            buffer.addAll(chunk);
            while (true) {
              final nl = buffer.indexOf(10);
              if (nl == -1) break;
              final line = utf8.decode(buffer.sublist(0, nl)).trim();
              buffer.removeRange(0, nl + 1);
              if (line.isNotEmpty) {
                lines.add(line);
                if (line.contains('"d"')) {
                  if (!doneSignal.isCompleted) doneSignal.complete();
                }
              }
            }
          });

          // Send header ONLY (0 payload bytes) while keeping socket open.
          client.write('$header\n');
          await client.flush();

          await doneSignal.future.timeout(const Duration(seconds: 3));
          final doneModel = await doneCompleter.future.timeout(
            const Duration(seconds: 3),
          );
          await client.close();

          expect(doneModel.phase, TransferPhase.done);
          expect(
            lines.any((l) => l.contains('"s":"r"') || l.contains('"s": "r"')),
            isTrue,
          );
          expect(
            File(p.join(receiveDir.path, 'empty_bundle', 'a.txt')).lengthSync(),
            0,
          );
          expect(
            File(p.join(receiveDir.path, 'empty_bundle', 'b.txt')).lengthSync(),
            0,
          );
        } finally {
          rx.controller.stop();
          await rx.stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test('default port constant matches expected protocol port', () {
      expect(AppConstants.transferPort, 62004);
    });
  });

  group('Zero-Router TLS + Multi-Stream v2 Protocol', () {
    late Directory tempRoot;
    late Directory receiveDir;
    late Directory sendDir;
    late Directory identityDirA;
    late Directory identityDirB;
    late DeviceIdentity rxIdentity;
    late DeviceIdentity txIdentity;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('daphq_v2_proto_');
      receiveDir = await Directory(p.join(tempRoot.path, 'recv')).create();
      sendDir = await Directory(p.join(tempRoot.path, 'send')).create();
      identityDirA = await Directory(p.join(tempRoot.path, 'id_a')).create();
      identityDirB = await Directory(p.join(tempRoot.path, 'id_b')).create();
      rxIdentity = await DeviceIdentityService(
        directoryProvider: () async => identityDirA,
      ).loadOrCreate();
      txIdentity = await DeviceIdentityService(
        directoryProvider: () async => identityDirB,
      ).loadOrCreate();
    });

    tearDown(() async {
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    });

    test('TLS pinned transfer succeeds on matching fingerprint and rejects spoofed fingerprint', () async {
      final sampleFile = File(p.join(sendDir.path, 'secret.txt'));
      await sampleFile.writeAsString('tls-authenticated-payload');

      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final done = Completer<void>();

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'TlsRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if (m.phase == TransferPhase.done && !done.isCompleted) {
              done.complete();
            }
          },
          onRequestAuth: (_, _, _, _) async => true,
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));

      try {
        // 1. Spoofed / wrong expected fingerprint MUST be rejected before plaintext leaks
        final badSender = SenderController();
        await expectLater(
          badSender.sendData(
            paths: [sampleFile.path],
            targetIp: '127.0.0.1',
            port: port,
            targetDeviceName: 'TlsRx',
            senderDeviceName: 'TlsTx',
            useTls: true,
            expectedPeerFingerprint: '00' * 32,
            localIdentity: txIdentity,
            onUpdate: (_) {},
          ),
          throwsA(isA<TransferSendException>()),
        );
        expect(File(p.join(receiveDir.path, 'secret.txt')).existsSync(), isFalse);

        // 2. Exact matching pinned fingerprint succeeds end-to-end
        final goodSender = SenderController();
        await goodSender.sendData(
          paths: [sampleFile.path],
          targetIp: '127.0.0.1',
          port: port,
          targetDeviceName: 'TlsRx',
          senderDeviceName: 'TlsTx',
          useTls: true,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          localIdentity: txIdentity,
          onUpdate: (_) {},
        );
        await done.future.timeout(const Duration(seconds: 5));

        final receivedFile = File(p.join(receiveDir.path, 'secret.txt'));
        expect(receivedFile.existsSync(), isTrue);
        expect(await receivedFile.readAsString(), 'tls-authenticated-payload');
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }
    });

    test('4-stream parallel TLS transfer delivers >2MB file, small files, and 0-byte file byte-identically', () async {
      final largeData = Uint8List.fromList(
        List<int>.generate(2 * 1024 * 1024 + 137, (i) => (i * 73 + 19) & 0xFF),
      );
      final smallData1 = utf8.encode('alpha-small-file');
      final smallData2 = utf8.encode('omega-trailing-file');

      final batchDir = await Directory(p.join(sendDir.path, 'turbo_pack')).create();
      await File(p.join(batchDir.path, '01_video.bin')).writeAsBytes(largeData);
      await File(p.join(batchDir.path, '02_note.txt')).writeAsBytes(smallData1);
      await File(p.join(batchDir.path, '03_empty.dat')).writeAsBytes(const <int>[]);
      await File(p.join(batchDir.path, '04_last.txt')).writeAsBytes(smallData2);

      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final done = Completer<void>();

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'TurboRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if (m.phase == TransferPhase.done && !done.isCompleted) {
              done.complete();
            }
          },
          onRequestAuth: (_, _, _, _) async => true,
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      try {
        final sender = SenderController();
        final senderPhases = <TransferPhase>[];
        await sender.sendData(
          paths: [batchDir.path],
          targetIp: '127.0.0.1',
          port: port,
          targetDeviceName: 'TurboRx',
          senderDeviceName: 'TurboTx',
          useTls: true,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          localIdentity: txIdentity,
          parallelStreams: 4,
          onUpdate: (m) => senderPhases.add(m.phase),
        );

        await done.future.timeout(const Duration(seconds: 8));

        final outDir = Directory(p.join(receiveDir.path, 'turbo_pack'));
        expect(await File(p.join(outDir.path, '01_video.bin')).readAsBytes(), equals(largeData));
        expect(await File(p.join(outDir.path, '02_note.txt')).readAsBytes(), equals(smallData1));
        expect(await File(p.join(outDir.path, '03_empty.dat')).readAsBytes(), isEmpty);
        expect(await File(p.join(outDir.path, '04_last.txt')).readAsBytes(), equals(smallData2));
        expect(
          outDir.listSync().where((e) => e.path.endsWith('.daphq-partial')),
          isEmpty,
        );
        expect(senderPhases, containsAll([TransferPhase.sending, TransferPhase.finalizing, TransferPhase.done]));
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }
    });

    test('Sender propagates directFrequencyProvider freqMhz to Receiver via v2 metadata header', () async {
      final sampleFile = File(p.join(sendDir.path, 'freq_sync.bin'));
      await sampleFile.writeAsBytes(utf8.encode('freq-sync-check'));

      final reportedFreqs = <int>[];
      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final done = Completer<void>();

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'FreqRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          onPeerReportedFrequency: reportedFreqs.add,
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if (m.phase == TransferPhase.done && !done.isCompleted) {
              done.complete();
            }
          },
          onRequestAuth: (_, _, _, _) async => true,
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      try {
        final sender = SenderController();
        await sender.sendData(
          paths: [sampleFile.path],
          targetIp: '127.0.0.1',
          port: port,
          targetDeviceName: 'FreqRx',
          senderDeviceName: 'FreqTx',
          useTls: true,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          localIdentity: txIdentity,
          directFrequencyProvider: () => 5200,
          onUpdate: (_) {},
        );
        await done.future.timeout(const Duration(seconds: 5));
        expect(reportedFreqs, contains(5200));
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }
    });

    test('reverse-connect TLS 4-stream mode transfers cleanly with outbound receiver sockets', () async {
      final largeData = Uint8List.fromList(
        List<int>.generate(900 * 1024, (i) => (i * 17) & 0xFF),
      );
      final file = File(p.join(sendDir.path, 'reverse.bin'));
      await file.writeAsBytes(largeData);

      final sender = SenderController();
      final reverseListening = Completer<int>();
      final rxDone = Completer<void>();

      final sendFuture = sender.sendData(
        paths: [file.path],
        targetIp: '127.0.0.1',
        port: 0,
        targetDeviceName: 'WinRx',
        senderDeviceName: 'AndroidTx',
        useTls: true,
        localIdentity: txIdentity,
        expectedPeerFingerprint: rxIdentity.certFingerprint,
        parallelStreams: 4,
        listenForReverseReceiver: true,
        onReverseListening: (boundPort) {
          if (!reverseListening.isCompleted) reverseListening.complete(boundPort);
        },
        onUpdate: (_) {},
      );

      final listenPort = await reverseListening.future.timeout(const Duration(seconds: 5));

      final receiver = ReceiverController();
      await receiver.acceptReverseTransfer(
        senderIp: '127.0.0.1',
        port: listenPort,
        saveDirectory: receiveDir.path,
        deviceName: 'WinRx',
        useTls: true,
        expectedSenderFingerprint: txIdentity.certFingerprint,
        localIdentity: rxIdentity,
        freeBytesProvider: () async => 1024 * 1024 * 1024,
        onUpdate: (m) {
          if (m.phase == TransferPhase.done && !rxDone.isCompleted) {
            rxDone.complete();
          }
        },
        onRequestAuth: (_, _, _, _) async => true,
      );

      await sendFuture.timeout(const Duration(seconds: 8));
      await rxDone.future.timeout(const Duration(seconds: 5));

      final recvFile = File(p.join(receiveDir.path, 'reverse.bin'));
      expect(recvFile.existsSync(), isTrue);
      expect(await recvFile.readAsBytes(), equals(largeData));
    });

    test('acceptReverseTransfer propagates directFrequencyProvider freqMhz to onPeerReportedFrequency', () async {
      final file = File(p.join(sendDir.path, 'reverse_freq.bin'));
      await file.writeAsBytes(utf8.encode('reverse-freq-sync'));

      final sender = SenderController();
      final reverseListening = Completer<int>();
      final rxDone = Completer<void>();
      final reportedFreqs = <int>[];

      final sendFuture = sender.sendData(
        paths: [file.path],
        targetIp: '127.0.0.1',
        port: 0,
        targetDeviceName: 'WinRx',
        senderDeviceName: 'AndroidTx',
        useTls: true,
        localIdentity: txIdentity,
        expectedPeerFingerprint: rxIdentity.certFingerprint,
        parallelStreams: 4,
        listenForReverseReceiver: true,
        directFrequencyProvider: () => 5200,
        onReverseListening: (boundPort) {
          if (!reverseListening.isCompleted) reverseListening.complete(boundPort);
        },
        onUpdate: (_) {},
      );

      final listenPort = await reverseListening.future.timeout(const Duration(seconds: 5));

      final receiver = ReceiverController();
      await receiver.acceptReverseTransfer(
        senderIp: '127.0.0.1',
        port: listenPort,
        saveDirectory: receiveDir.path,
        deviceName: 'WinRx',
        useTls: true,
        expectedSenderFingerprint: txIdentity.certFingerprint,
        localIdentity: rxIdentity,
        onPeerReportedFrequency: reportedFreqs.add,
        freeBytesProvider: () async => 1024 * 1024 * 1024,
        onUpdate: (m) {
          if (m.phase == TransferPhase.done && !rxDone.isCompleted) {
            rxDone.complete();
          }
        },
        onRequestAuth: (_, _, _, _) async => true,
      );

      await sendFuture.timeout(const Duration(seconds: 8));
      await rxDone.future.timeout(const Duration(seconds: 5));

      expect(reportedFreqs, contains(5200));
    });

    test('verifies ECDSA sender proof over TLS and flags spoofed peer metadata as unverified', () async {
      final sampleFile = File(p.join(sendDir.path, 'auth_check.txt'));
      await sampleFile.writeAsString('signed-transfer-ok');

      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final verifiedFlags = <bool>[];
      final done = Completer<void>();

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'VerifyRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if (m.phase == TransferPhase.done && !done.isCompleted) {
              done.complete();
            }
          },
          onRequestAuth: (_, _, _, _) async => false,
          onRequestAuthV2: (req) async {
            verifiedFlags.add(req.isIdentityVerified);
            return req.isIdentityVerified;
          },
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      try {
        // 1. Spoofed control frame claiming txIdentity without valid senderProof
        final spoofSock = await connectTransferSocket(
          host: '127.0.0.1',
          port: port,
          useTls: true,
          timeout: const Duration(seconds: 5),
          expectedPeerFingerprint: rxIdentity.certFingerprint,
        );
        spoofSock.write(
          '${jsonEncode({
            'v': 2,
            'sessionId': 'spoof-sid-1',
            'streams': 1,
            'senderPeerId': txIdentity.peerId,
            'senderFp': txIdentity.certFingerprint,
            'fileName': 'spoof.txt',
            'fileSize': 5,
            'senderDeviceName': 'Spoofer',
            'isFolder': false,
            'files': [
              {'path': 'spoof.txt', 'size': 5},
            ],
          })}\n',
        );
        await spoofSock.flush();
        final reply = await BufferedSocketReader(spoofSock).readJsonHeader(
          timeout: const Duration(seconds: 5),
          maxHeaderBytes: 64 * 1024,
        );
        expect(reply?.header['status'], 'REJECTED');
        spoofSock.destroy();

        // 2. Real SenderController signs proof bound to rxIdentity cert & session
        await SenderController().sendData(
          paths: [sampleFile.path],
          targetIp: '127.0.0.1',
          port: port,
          targetDeviceName: 'VerifyRx',
          senderDeviceName: 'VerifyTx',
          useTls: true,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          localIdentity: txIdentity,
          onUpdate: (_) {},
        );
        await done.future.timeout(const Duration(seconds: 5));

        expect(verifiedFlags, equals([false, true]));
        expect(File(p.join(receiveDir.path, 'spoof.txt')).existsSync(), isFalse);
        expect(File(p.join(receiveDir.path, 'auth_check.txt')).existsSync(), isTrue);
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }
    });

    test('connectTransferSocket refuses unpinned TLS without expected fingerprint or verifier', () async {
      await expectLater(
        connectTransferSocket(
          host: '127.0.0.1',
          port: 1,
          useTls: true,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('multi-stream receiver rejects duplicate overlapping chunks instead of completing partial file', () async {
      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final failedOrCancelled = Completer<TransferModel>();

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'RangeRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if ((m.phase == TransferPhase.failed ||
                    m.phase == TransferPhase.cancelled) &&
                !failedOrCancelled.isCompleted) {
              failedOrCancelled.complete(m);
            }
          },
          onRequestAuth: (_, _, _, _) async => true,
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      try {
        const sid = 'dup-range-sid';
        final ctrl = await connectTransferSocket(
          host: '127.0.0.1',
          port: port,
          useTls: true,
          timeout: const Duration(seconds: 5),
          expectedPeerFingerprint: rxIdentity.certFingerprint,
        );
        ctrl.write(
          '${jsonEncode({
            'v': 2,
            'sessionId': sid,
            'streams': 2,
            'fileName': 'dup.bin',
            'fileSize': 1024,
            'senderDeviceName': 'RangeTx',
            'isFolder': false,
            'files': [
              {'path': 'dup.bin', 'size': 1024},
            ],
          })}\n',
        );
        await ctrl.flush();

        final ready = await BufferedSocketReader(ctrl).readJsonHeader(
          timeout: const Duration(seconds: 5),
          maxHeaderBytes: 64 * 1024,
        );
        expect(ready?.header['s'], 'r');

        // Send overlapping [0, 512) twice across two workers (sums to 1024, misses [512, 1024))
        final chunk = Uint8List.fromList(List<int>.filled(512, 0x42));
        Future<void> sendDupWorker(int idx) async {
          final w = await connectTransferSocket(
            host: '127.0.0.1',
            port: port,
            useTls: true,
            timeout: const Duration(seconds: 5),
            expectedPeerFingerprint: rxIdentity.certFingerprint,
          );
          w.write(
            '${jsonEncode({'v': 2, 'role': 'data', 'sessionId': sid, 'workerIndex': idx})}\n',
          );
          w.add(buildV2FrameHeader(fileIndex: 0, fileOffset: 0, payloadLength: 512));
          w.add(chunk);
          w.add(buildV2EofFrame());
          await w.flush();
          await w.close();
        }

        await Future.wait([sendDupWorker(0), sendDupWorker(1)]);
        await failedOrCancelled.future.timeout(const Duration(seconds: 5));
        ctrl.destroy();

        expect(File(p.join(receiveDir.path, 'dup.bin')).existsSync(), isFalse);
        expect(
          receiveDir.listSync().where((e) => e.path.endsWith('.daphq-partial')),
          isEmpty,
        );
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }
    });

    test('reverse-connect rejects wrong reverseToken and missing receiver proof over TLS', () async {
      final sampleFile = File(p.join(sendDir.path, 'rev_sec.bin'));
      await sampleFile.writeAsString('protected-reverse-payload');

      final sender = SenderController();
      final reverseListening = Completer<int>();
      final sendDone = Completer<Object?>();

      unawaited(
        sender
            .sendData(
              paths: [sampleFile.path],
              targetIp: '127.0.0.1',
              port: 0,
              targetDeviceName: 'WinRx',
              senderDeviceName: 'AndroidTx',
              useTls: true,
              localIdentity: txIdentity,
              expectedPeerFingerprint: rxIdentity.certFingerprint,
              parallelStreams: 2,
              listenForReverseReceiver: true,
              reverseAuthToken: 'expected-secret-token',
              onReverseListening: (boundPort) {
                if (!reverseListening.isCompleted) reverseListening.complete(boundPort);
              },
              onUpdate: (_) {},
            )
            .then((_) {
              if (!sendDone.isCompleted) sendDone.complete(null);
            })
            .catchError((Object err) {
              if (!sendDone.isCompleted) sendDone.complete(err);
            }),
      );

      final port = await reverseListening.future.timeout(const Duration(seconds: 5));

      // 1. Rogue reverse_control with wrong reverseToken must be rejected/closed immediately
      final badTokSock = await connectTransferSocket(
        host: '127.0.0.1',
        port: port,
        useTls: true,
        timeout: const Duration(seconds: 5),
        expectedPeerFingerprint: txIdentity.certFingerprint,
      );
      badTokSock.write(
        '${jsonEncode({
          'v': 2,
          'role': 'reverse_control',
          'reverseToken': 'wrong-token',
        })}\n',
      );
      await badTokSock.flush();
      final rejectedRead = await BufferedSocketReader(badTokSock).readJsonHeader(
        timeout: const Duration(seconds: 3),
        maxHeaderBytes: 64 * 1024,
      );
      expect(rejectedRead, isNull);
      badTokSock.destroy();

      // 2. Reverse_control with valid token that sends READY without receiverProof must fail
      final spoofReadySock = await connectTransferSocket(
        host: '127.0.0.1',
        port: port,
        useTls: true,
        timeout: const Duration(seconds: 5),
        expectedPeerFingerprint: txIdentity.certFingerprint,
      );
      spoofReadySock.write(
        '${jsonEncode({
          'v': 2,
          'role': 'reverse_control',
          'reverseToken': 'expected-secret-token',
        })}\n',
      );
      await spoofReadySock.flush();

      final metaHeader = await BufferedSocketReader(spoofReadySock).readJsonHeader(
        timeout: const Duration(seconds: 5),
        maxHeaderBytes: 64 * 1024,
      );
      expect(metaHeader?.header['fileName'], 'rev_sec.bin');

      spoofReadySock.write(
        '${jsonEncode({
          's': 'r',
          'v': 2,
          'streams': 2,
          'receiverPeerId': rxIdentity.peerId,
          'receiverFp': rxIdentity.certFingerprint,
        })}\n',
      );
      await spoofReadySock.flush();

      final err = await sendDone.future.timeout(const Duration(seconds: 5));
      spoofReadySock.destroy();
      expect(err, isA<TransferSendException>());
    });

    test('concurrent acceptReverseTransfer bails cleanly without clobbering active transfer or firing onDone', () async {
      final payloadBytes = utf8.encode('primary-active-transfer-bytes');
      final sampleFile = File(p.join(sendDir.path, 'active_first.txt'));
      await sampleFile.writeAsBytes(payloadBytes);

      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final firstAuthEntered = Completer<void>();
      final firstAuthDecision = Completer<bool>();
      final firstDone = Completer<void>();

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'ConcurrentRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if (m.phase == TransferPhase.done && !firstDone.isCompleted) {
              firstDone.complete();
            }
          },
          onRequestAuth: (_, _, _, _) async => false,
          onRequestAuthV2: (_) async {
            if (!firstAuthEntered.isCompleted) firstAuthEntered.complete();
            return firstAuthDecision.future;
          },
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      try {
        final sendFuture = SenderController().sendData(
          paths: [sampleFile.path],
          targetIp: '127.0.0.1',
          port: port,
          targetDeviceName: 'ConcurrentRx',
          senderDeviceName: 'Tx1',
          useTls: true,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          localIdentity: txIdentity,
          onUpdate: (_) {},
        );

        await firstAuthEntered.future.timeout(const Duration(seconds: 5));

        bool concurrentDoneFired = false;
        await receiver.acceptReverseTransfer(
          senderIp: '127.0.0.1',
          port: 65001,
          saveDirectory: receiveDir.path,
          deviceName: 'ConcurrentRx',
          useTls: true,
          localIdentity: rxIdentity,
          onUpdate: (_) {},
          onRequestAuth: (_, _, _, _) async => true,
          onDone: () {
            concurrentDoneFired = true;
          },
        );
        expect(concurrentDoneFired, isFalse);

        firstAuthDecision.complete(true);
        await sendFuture.timeout(const Duration(seconds: 5));
        await firstDone.future.timeout(const Duration(seconds: 5));

        final saved = File(p.join(receiveDir.path, 'active_first.txt'));
        expect(saved.existsSync(), isTrue);
        expect(await saved.readAsBytes(), equals(payloadBytes));
        expect(concurrentDoneFired, isFalse);
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }
    });

    test('0-byte file in failed v2 batch is not created in saveDirectory before finalizeAndVerify', () async {
      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final failedOrCancelled = Completer<TransferModel>();

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'ZeroOrderRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if ((m.phase == TransferPhase.failed ||
                    m.phase == TransferPhase.cancelled) &&
                !failedOrCancelled.isCompleted) {
              failedOrCancelled.complete(m);
            }
          },
          onRequestAuth: (_, _, _, _) async => true,
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      try {
        const sid = 'zero-order-abort-sid';
        final ctrl = await connectTransferSocket(
          host: '127.0.0.1',
          port: port,
          useTls: true,
          timeout: const Duration(seconds: 5),
          expectedPeerFingerprint: rxIdentity.certFingerprint,
        );
        ctrl.write(
          '${jsonEncode({
            'v': 2,
            'sessionId': sid,
            'streams': 2,
            'fileName': 'zero_pack',
            'fileSize': 1024,
            'senderDeviceName': 'ZeroTx',
            'isFolder': true,
            'files': [
              {'path': 'zero_first.txt', 'size': 0},
              {'path': 'incomplete_second.bin', 'size': 1024},
            ],
          })}\n',
        );
        await ctrl.flush();

        final ready = await BufferedSocketReader(ctrl).readJsonHeader(
          timeout: const Duration(seconds: 5),
          maxHeaderBytes: 64 * 1024,
        );
        expect(ready?.header['s'], 'r');

        // Both workers send EOF without writing incomplete_second.bin
        Future<void> sendEmptyWorker(int idx) async {
          final w = await connectTransferSocket(
            host: '127.0.0.1',
            port: port,
            useTls: true,
            timeout: const Duration(seconds: 5),
            expectedPeerFingerprint: rxIdentity.certFingerprint,
          );
          w.write(
            '${jsonEncode({'v': 2, 'role': 'data', 'sessionId': sid, 'workerIndex': idx})}\n',
          );
          w.add(buildV2EofFrame());
          await w.flush();
          await w.close();
        }

        await Future.wait([sendEmptyWorker(0), sendEmptyWorker(1)]);
        await failedOrCancelled.future.timeout(const Duration(seconds: 5));
        ctrl.destroy();

        expect(File(p.join(receiveDir.path, 'zero_first.txt')).existsSync(), isFalse);
        expect(File(p.join(receiveDir.path, 'incomplete_second.bin')).existsSync(), isFalse);
        expect(
          receiveDir.listSync().where((e) => e.path.endsWith('.daphq-partial')),
          isEmpty,
        );
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }
    });

    test(
      'direct_control over LAN TLS verifies ECDSA proof, returns Direct host credentials, and rejects spoofed requests',
      () async {
        final rxIdentity = await DeviceIdentityService(
          directoryProvider: () async => Directory(p.join(tempRoot.path, 'dc_rx')),
        ).loadOrCreate();
        final txIdentity = await DeviceIdentityService(
          directoryProvider: () async => Directory(p.join(tempRoot.path, 'dc_tx')),
        ).loadOrCreate();
        final receiver = ReceiverController();
        final listening = Completer<int>();
        final stopped = Completer<void>();
        DirectControlRequest? observedReq;

        unawaited(
          receiver.startReceiver(
            saveDirectory: receiveDir.path,
            deviceName: 'DirectControlRx',
            port: 0,
            tlsContext: rxIdentity.createServerContext(),
            localIdentity: rxIdentity,
            onListening: (p0) {
              if (!listening.isCompleted) listening.complete(p0);
            },
            freeBytesProvider: () async => 1024 * 1024 * 1024,
            onUpdate: (_) {},
            onRequestAuth: (_, _, _, _) async => true,
            onDirectControlRequest: (req) async {
              observedReq = req;
              return <String, dynamic>{
                'ok': true,
                'ssid': 'DIRECT-DQ-9911',
                'psk': 'SecretPass9911',
                'hostIp': '192.168.49.1',
                'port': 62004,
                'frequencyMhz': 5180,
                'reverseConnect': false,
              };
            },
            onDone: () {
              if (!stopped.isCompleted) stopped.complete();
            },
          ),
        );

        final port = await listening.future.timeout(const Duration(seconds: 5));
        try {
          // 1. Valid signed request succeeds without ending receiver loop
          final resp = await sendDirectControl(
            host: '127.0.0.1',
            port: port,
            localIdentity: txIdentity,
            localDeviceName: 'WinLaptop',
            localPort: 62004,
            action: 'startHostAndWait',
            expectedPeerFingerprint: rxIdentity.certFingerprint,
          );
          expect(resp['ok'], isTrue);
          expect(resp['ssid'], 'DIRECT-DQ-9911');
          expect(resp['hostIp'], '192.168.49.1');
          expect(observedReq?.isIdentityVerified, isTrue);
          expect(observedReq?.senderPeerId, txIdentity.peerId);
          expect(observedReq?.action, 'startHostAndWait');

          // 2. Spoofed / invalid ECDSA signature is strictly rejected
          final rogueSock = await connectTransferSocket(
            host: '127.0.0.1',
            port: port,
            useTls: true,
            timeout: const Duration(seconds: 5),
            expectedPeerFingerprint: rxIdentity.certFingerprint,
          );
          rogueSock.write(
            '${jsonEncode({
              'v': 2,
              'role': 'direct_control',
              'requestId': 'forged-req-1',
              'action': 'joinHost',
              'peerId': txIdentity.peerId,
              'peerName': 'EvilSpoof',
              'senderFp': txIdentity.certFingerprint,
              'senderCertPem': txIdentity.certificatePem,
              'senderProof': 'invalid-base64-sig',
              'ssid': 'EVIL-AP',
              'psk': '12345678',
              'hostIp': '10.0.0.9',
            })}\n',
          );
          await rogueSock.flush();
          final rogueResp = await BufferedSocketReader(rogueSock).readJsonHeader(
            maxHeaderBytes: 64 * 1024,
            timeout: const Duration(seconds: 5),
          );
          rogueSock.destroy();
          expect(rogueResp?.header['ok'], isFalse);
          expect(rogueResp?.header['error'], 'unverifiedSender');
        } finally {
          receiver.stop();
          await stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );

    test('TransferSpeedTracker smooths instantaneous spikes with EMA and aligns chunk size to 512 KB', () {
      expect(daphqChunkSizeBytes, 512 * 1024);

      final emitted = <double>[];
      var fakeNow = DateTime(2026, 11, 14, 12, 0, 0);
      final tracker = TransferSpeedTracker(
        nowProvider: () => fakeNow,
        intervalMs: 500,
        alpha: 0.35,
      );

      // Sub-interval writes do not emit noisy samples.
      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      tracker.recordBytes(10 * 1024 * 1024, 'a.bin', (spd, _) => emitted.add(spd));
      expect(emitted, isEmpty);

      // Sample 1 after 600ms (~20 MB total over 600ms = ~33.33 MB/s baseline).
      fakeNow = fakeNow.add(const Duration(milliseconds: 500));
      tracker.recordBytes(10 * 1024 * 1024, 'a.bin', (spd, _) => emitted.add(spd));
      expect(emitted, hasLength(1));
      final first = emitted.first;
      expect(first, closeTo(33.33, 0.2));

      // Sample 2 suffers a stall (0 bytes extra, 550ms elapsed with only small 1 MB tail).
      fakeNow = fakeNow.add(const Duration(milliseconds: 550));
      tracker.recordBytes(1 * 1024 * 1024, 'a.bin', (spd, _) => emitted.add(spd));
      expect(emitted, hasLength(2));
      // Instant speed was ~1.81 MB/s, EMA should cushion (> 20 MB/s, not crash to 1.8).
      expect(emitted[1], greaterThan(20.0));
      expect(emitted[1], lessThan(first));
    });

    test('V2OrderedChunkCoalescer coalesces out-of-order chunks and resolves delayed head chunks', () {
      const kChunk = 512 * 1024;
      Uint8List makeChunk(int offset, int fillByte) =>
          Uint8List(kChunk)..fillRange(0, kChunk, fillByte);

      final coalescer = V2OrderedChunkCoalescer();
      coalescer.enqueue(kChunk, makeChunk(kChunk, 0x22));
      coalescer.enqueue(kChunk * 2, makeChunk(kChunk * 2, 0x33));
      coalescer.enqueue(kChunk * 3, makeChunk(kChunk * 3, 0x44));
      expect(coalescer.pendingBytes, kChunk * 3);

      // Without fallback, holds briefly for head offset 0 so contiguous runs merge.
      expect(
        coalescer.takeNextBatch(maxBatchBytes: 2 * 1024 * 1024),
        isNull,
      );

      // Once offset 0 arrives, all 4 chunks coalesce into one 2 MB batch.
      coalescer.enqueue(0, makeChunk(0, 0x11));
      final batch = coalescer.takeNextBatch(maxBatchBytes: 2 * 1024 * 1024);
      expect(batch, isNotNull);
      expect(batch!.offset, 0);
      expect(batch.bytes.length, 4 * kChunk);
      expect(batch.bytes[0], 0x11);
      expect(batch.bytes[kChunk], 0x22);
      expect(batch.bytes[kChunk * 2], 0x33);
      expect(batch.bytes[kChunk * 3], 0x44);
      expect(coalescer.pendingBytes, 0);
      expect(coalescer.nextInOrderOffset, 4 * kChunk);

      // Out-of-order high-water fallback test: flush hole-adjacent tail, then bridge head.
      final skewed = V2OrderedChunkCoalescer();
      skewed.enqueue(kChunk, makeChunk(kChunk, 0xAA));
      skewed.enqueue(kChunk * 2, makeChunk(kChunk * 2, 0xBB));
      final tailBatch = skewed.takeNextBatch(allowOutOfOrderFallback: true);
      expect(tailBatch?.offset, kChunk);
      expect(tailBatch?.bytes.length, 2 * kChunk);
      expect(skewed.nextInOrderOffset, 0);

      skewed.enqueue(0, makeChunk(0, 0x01));
      skewed.enqueue(kChunk * 3, makeChunk(kChunk * 3, 0xCC));
      final headBatch = skewed.takeNextBatch();
      expect(headBatch?.offset, 0);
      expect(headBatch?.bytes.length, kChunk);
      expect(skewed.nextInOrderOffset, kChunk * 3);

      final tail2 = skewed.takeNextBatch();
      expect(tail2?.offset, kChunk * 3);
      expect(skewed.nextInOrderOffset, kChunk * 4);
    });

    test('4-stream 512 KB pipelined TLS transfer delivers >3.2 MB file byte-identically', () async {
      const size = 3 * 1024 * 1024 + 256 * 1024;
      final sourceBytes = Uint8List(size);
      for (int i = 0; i < size; i++) {
        sourceBytes[i] = (i * 7 + (i >> 9)) & 0xFF;
      }
      final srcFile = File(p.join(sendDir.path, 'large_pipeline.bin'));
      await srcFile.writeAsBytes(sourceBytes);

      final receiver = ReceiverController();
      final listening = Completer<int>();
      final stopped = Completer<void>();
      final done = Completer<void>();
      final updates = <TransferModel>[];

      unawaited(
        receiver.startReceiver(
          saveDirectory: receiveDir.path,
          deviceName: 'PipeRx',
          port: 0,
          tlsContext: rxIdentity.createServerContext(),
          localIdentity: rxIdentity,
          onListening: (boundPort) {
            if (!listening.isCompleted) listening.complete(boundPort);
          },
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            updates.add(m);
            if (m.phase == TransferPhase.done && !done.isCompleted) {
              done.complete();
            }
          },
          onRequestAuth: (_, _, _, _) async => false,
          onRequestAuthV2: (req) async => req.isIdentityVerified,
          onDone: () {
            if (!stopped.isCompleted) stopped.complete();
          },
        ),
      );

      final port = await listening.future.timeout(const Duration(seconds: 5));
      try {
        await SenderController().sendData(
          paths: [srcFile.path],
          targetIp: '127.0.0.1',
          port: port,
          targetDeviceName: 'PipeRx',
          senderDeviceName: 'PipeTx',
          useTls: true,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          localIdentity: txIdentity,
          onUpdate: (_) {},
        );
        await done.future.timeout(const Duration(seconds: 15));
      } finally {
        receiver.stop();
        await stopped.future.timeout(const Duration(seconds: 5));
      }

      final receivedFile = File(p.join(receiveDir.path, 'large_pipeline.bin'));
      expect(await receivedFile.exists(), isTrue);
      expect(await receivedFile.readAsBytes(), equals(sourceBytes));
      final partials = receiveDir
          .listSync()
          .where((e) => e.path.endsWith('.daphq-partial'))
          .toList();
      expect(partials, isEmpty);
    });

    test(
      'reverse-connect TLS auth rejection stops 4-stream sender immediately with TransferPhase.cancelled',
      () async {
        final payload = Uint8List.fromList(List<int>.generate(128 * 1024, (i) => i & 0xFF));
        final file = File(p.join(sendDir.path, 'reject_me.bin'));
        await file.writeAsBytes(payload);

        final sender = SenderController();
        final reverseListening = Completer<int>();
        final updates = <TransferModel>[];

        final sendFuture = sender.sendData(
          paths: [file.path],
          targetIp: '127.0.0.1',
          port: 0,
          targetDeviceName: 'WinRx',
          senderDeviceName: 'AndroidTx',
          useTls: true,
          localIdentity: txIdentity,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          parallelStreams: 4,
          listenForReverseReceiver: true,
          onReverseListening: (boundPort) {
            if (!reverseListening.isCompleted) {
              reverseListening.complete(boundPort);
            }
          },
          onUpdate: updates.add,
        );

        final listenPort = await reverseListening.future.timeout(const Duration(seconds: 5));
        final sendExpectation = expectLater(
          sendFuture.timeout(const Duration(seconds: 3)),
          throwsA(
            isA<TransferSendException>()
                .having((e) => e.phase, 'phase', TransferPhase.cancelled)
                .having((e) => e.message.toLowerCase(), 'message', contains('rejected')),
          ),
        );
        final receiver = ReceiverController();

        await receiver.acceptReverseTransfer(
          senderIp: '127.0.0.1',
          port: listenPort,
          saveDirectory: receiveDir.path,
          deviceName: 'WinRx',
          useTls: true,
          expectedSenderFingerprint: txIdentity.certFingerprint,
          localIdentity: rxIdentity,
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (_) {},
          onRequestAuth: (_, _, _, _) async => false,
          onRequestAuthV2: (_) async => false,
        );

        await sendExpectation;
        expect(updates.last.phase, TransferPhase.cancelled);
        expect(File(p.join(receiveDir.path, 'reject_me.bin')).existsSync(), isFalse);
      },
    );

    test(
      'mid-transfer cancelActiveTransfer stops 4-stream TLS reverse sender immediately',
      () async {
        const size = 4 * 1024 * 1024;
        final payload = Uint8List.fromList(
          List<int>.generate(size, (i) => (i * 13) & 0xFF),
        );
        final file = File(p.join(sendDir.path, 'cancel_mid_stream.bin'));
        await file.writeAsBytes(payload);

        final sender = SenderController();
        final reverseListening = Completer<int>();
        final startedReceiving = Completer<void>();
        final senderUpdates = <TransferModel>[];

        final sendFuture = sender.sendData(
          paths: [file.path],
          targetIp: '127.0.0.1',
          port: 0,
          targetDeviceName: 'WinRx',
          senderDeviceName: 'AndroidTx',
          useTls: true,
          localIdentity: txIdentity,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          parallelStreams: 4,
          listenForReverseReceiver: true,
          onReverseListening: (boundPort) {
            if (!reverseListening.isCompleted) {
              reverseListening.complete(boundPort);
            }
          },
          onUpdate: senderUpdates.add,
        );

        final listenPort = await reverseListening.future.timeout(const Duration(seconds: 5));
        final receiver = ReceiverController();

        final acceptFuture = receiver.acceptReverseTransfer(
          senderIp: '127.0.0.1',
          port: listenPort,
          saveDirectory: receiveDir.path,
          deviceName: 'WinRx',
          useTls: true,
          expectedSenderFingerprint: txIdentity.certFingerprint,
          localIdentity: rxIdentity,
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (m) {
            if (m.phase == TransferPhase.receiving && !startedReceiving.isCompleted) {
              startedReceiving.complete();
            }
          },
          onRequestAuth: (_, _, _, _) async => true,
          onRequestAuthV2: (_) async => true,
        );

        await startedReceiving.future.timeout(const Duration(seconds: 5));
        receiver.cancelActiveTransfer(reason: 'Cancelled by Receiver');

        await expectLater(
          sendFuture.timeout(const Duration(seconds: 3)),
          throwsA(
            isA<TransferSendException>().having(
              (e) => e.phase,
              'phase',
              TransferPhase.cancelled,
            ),
          ),
        );
        await acceptFuture.timeout(const Duration(seconds: 3));
        expect(senderUpdates.last.phase, TransferPhase.cancelled);
        expect(
          File(p.join(receiveDir.path, 'cancel_mid_stream.bin')).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'reverse READY handshake echoes directFrequencyMhz and forward mid-stream cancel stops sender',
      () async {
        const size = 3 * 1024 * 1024;
        final payload = Uint8List.fromList(
          List<int>.generate(size, (i) => (i * 19) & 0xFF),
        );
        final okFile = File(p.join(sendDir.path, 'freq_echo.bin'));
        await okFile.writeAsBytes(payload.sublist(0, 65536));

        final sender = SenderController();
        final reverseListening = Completer<int>();
        final reportedFreqs = <int>[];

        final sendFuture = sender.sendData(
          paths: [okFile.path],
          targetIp: '127.0.0.1',
          port: 0,
          targetDeviceName: 'WinRxFreq',
          senderDeviceName: 'AndroidTxFreq',
          useTls: true,
          localIdentity: txIdentity,
          expectedPeerFingerprint: rxIdentity.certFingerprint,
          parallelStreams: 4,
          listenForReverseReceiver: true,
          onReverseListening: (boundPort) {
            if (!reverseListening.isCompleted) {
              reverseListening.complete(boundPort);
            }
          },
          onPeerReportedFrequency: reportedFreqs.add,
          onUpdate: (_) {},
        );

        final listenPort = await reverseListening.future.timeout(const Duration(seconds: 5));
        final receiver = ReceiverController();
        await receiver.acceptReverseTransfer(
          senderIp: '127.0.0.1',
          port: listenPort,
          saveDirectory: receiveDir.path,
          deviceName: 'WinRxFreq',
          useTls: true,
          expectedSenderFingerprint: txIdentity.certFingerprint,
          localIdentity: rxIdentity,
          directFrequencyMhz: 5745,
          freeBytesProvider: () async => 1024 * 1024 * 1024,
          onUpdate: (_) {},
          onRequestAuth: (_, _, _, _) async => true,
          onRequestAuthV2: (_) async => true,
        );
        await sendFuture.timeout(const Duration(seconds: 5));
        expect(reportedFreqs, contains(5745));

        // Now verify forward 4-stream TLS mid-transfer cancelActiveTransfer stops sender immediately.
        final largeFile = File(p.join(sendDir.path, 'forward_cancel_mid.bin'));
        await largeFile.writeAsBytes(payload);
        final fwdReceiver = ReceiverController();
        final listening = Completer<int>();
        final receivingStarted = Completer<void>();
        final stopped = Completer<void>();

        unawaited(
          fwdReceiver.startReceiver(
            saveDirectory: receiveDir.path,
            deviceName: 'AndroidRx',
            port: 0,
            tlsContext: rxIdentity.createServerContext(),
            localIdentity: rxIdentity,
            onListening: (p) {
              if (!listening.isCompleted) listening.complete(p);
            },
            freeBytesProvider: () async => 1024 * 1024 * 1024,
            onUpdate: (m) {
              if (m.phase == TransferPhase.receiving && !receivingStarted.isCompleted) {
                receivingStarted.complete();
              }
            },
            onRequestAuth: (_, _, _, _) async => true,
            onRequestAuthV2: (_) async => true,
            onDone: () {
              if (!stopped.isCompleted) stopped.complete();
            },
          ),
        );

        final fwdPort = await listening.future.timeout(const Duration(seconds: 5));
        try {
          final fwdSender = SenderController();
          final fwdSendFuture = fwdSender.sendData(
            paths: [largeFile.path],
            targetIp: '127.0.0.1',
            port: fwdPort,
            targetDeviceName: 'AndroidRx',
            senderDeviceName: 'WinTx',
            useTls: true,
            expectedPeerFingerprint: rxIdentity.certFingerprint,
            localIdentity: txIdentity,
            parallelStreams: 4,
            onUpdate: (_) {},
          );
          await receivingStarted.future.timeout(const Duration(seconds: 5));
          final fwdExpectation = expectLater(
            fwdSendFuture.timeout(const Duration(seconds: 3)),
            throwsA(
              isA<TransferSendException>().having(
                (e) => e.phase,
                'phase',
                TransferPhase.cancelled,
              ),
            ),
          );
          fwdReceiver.cancelActiveTransfer(reason: 'Cancelled by Receiver');
          await fwdExpectation;
          await fwdReceiver.waitForPendingRejection().timeout(const Duration(seconds: 2));
        } finally {
          fwdReceiver.stop();
          await stopped.future.timeout(const Duration(seconds: 5));
        }
      },
    );
  });

  group('bindTransferServer resilient fallback', () {
    Future<int> reserveFreeTcpPort() async {
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final port = probe.port;
      await probe.close();
      return port;
    }

    test('falls back immediately to alternate TCP port when primary throws OS error 10013', () async {
      final fallbackPort = await reserveFreeTcpPort();
      final attempts = <int>[];

      final bound = await bindTransferServer(
        port: 62004,
        fallbackPorts: [fallbackPort],
        retryDelay: const Duration(milliseconds: 10),
        maxAttempts: 2,
        isCancelled: () => false,
        onAttempt: (attempt, _) => attempts.add(attempt),
        plainBinder: (addr, port, {bool shared = true}) async {
          if (port == 62004) {
            throw const SocketException(
              'Excluded by Windows NAT',
              osError: OSError('WSAEACCES', 10013),
            );
          }
          return ServerSocket.bind(addr, port, shared: shared);
        },
      );

      expect(bound.plain, isNotNull);
      addTearDown(() => bound.plain!.close());
      expect(bound.plain!.port, fallbackPort);
      expect(attempts, [1]);

      final client = await Socket.connect('127.0.0.1', fallbackPort);
      await client.close();
    });

    test('falls back immediately to alternate TCP port when primary throws OS error 10048', () async {
      final fallbackPort = await reserveFreeTcpPort();

      final bound = await bindTransferServer(
        port: 62004,
        fallbackPorts: [fallbackPort],
        retryDelay: const Duration(milliseconds: 10),
        maxAttempts: 2,
        isCancelled: () => false,
        onAttempt: (_, _) {},
        plainBinder: (addr, port, {bool shared = true}) async {
          if (port == 62004) {
            throw const SocketException(
              'Address already in use',
              osError: OSError('WSAEADDRINUSE', 10048),
            );
          }
          return ServerSocket.bind(addr, port, shared: shared);
        },
      );

      expect(bound.plain, isNotNull);
      addTearDown(() => bound.plain!.close());
      expect(bound.plain!.port, fallbackPort);
    });
  });
}
