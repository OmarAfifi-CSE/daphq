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
  });
}
