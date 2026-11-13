import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daphq/controllers/receiver_controller.dart';
import 'package:daphq/controllers/sender_controller.dart';
import 'package:daphq/core/app_constants.dart';
import 'package:daphq/models/transfer_model.dart';

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
}
