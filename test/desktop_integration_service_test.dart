import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daphq/services/desktop_integration_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempQueueDir;

  setUp(() {
    tempQueueDir = Directory.systemTemp.createTempSync('daphq_queue_test_');
    DesktopIntegrationService.debugResetForTest();
    DesktopIntegrationService.debugFocusWindowOverride = () async {};
  });

  tearDown(() {
    DesktopIntegrationService.debugResetForTest();
    if (tempQueueDir.existsSync()) {
      tempQueueDir.deleteSync(recursive: true);
    }
  });

  test(
    'event-driven Directory.watch picks up atomic .tmp -> .json renames in chronological order',
    () async {
      final receivedBatches = <List<String>>[];
      final completer = Completer<void>();
      final sub = DesktopIntegrationService.fileStream.listen((paths) {
        receivedBatches.add(paths);
        if (receivedBatches.expand((b) => b).length >= 3 &&
            !completer.isCompleted) {
          completer.complete();
        }
      });

      try {
        DesktopIntegrationService.debugStartQueueWatcher(tempQueueDir.path);
        // Allow native ReadDirectoryChangesW stream to arm.
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Write two atomic batches (.tmp -> .json) with Unicode & Emoji paths.
        final tmp1 = File(p.join(tempQueueDir.path, 'shell_0001.tmp'));
        tmp1.writeAsStringSync(
          jsonEncode([r'C:\Users\عمر\📁 ملفات\فيديو 🎬.mp4']),
          flush: true,
        );
        // While only .tmp exists, it must NOT be consumed.
        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(receivedBatches, isEmpty);

        tmp1.renameSync(p.join(tempQueueDir.path, 'shell_0001.json'));

        final tmp2 = File(p.join(tempQueueDir.path, 'shell_0002.tmp'));
        tmp2.writeAsStringSync(
          jsonEncode([r'D:\batch\two.bin', r'D:\batch\three.bin']),
          flush: true,
        );
        tmp2.renameSync(p.join(tempQueueDir.path, 'shell_0002.json'));

        await completer.future.timeout(const Duration(seconds: 3));

        final flat = receivedBatches.expand((b) => b).toList();
        expect(flat, [
          r'C:\Users\عمر\📁 ملفات\فيديو 🎬.mp4',
          r'D:\batch\two.bin',
          r'D:\batch\three.bin',
        ]);
        expect(
          tempQueueDir
              .listSync()
              .where((e) => e.path.endsWith('.json'))
              .toList(),
          isEmpty,
        );
      } finally {
        await sub.cancel();
      }
    },
  );

  test(
    'cold-start queued files before listener attaches buffer cleanly and flush in order',
    () async {
      // Simulate cold boot: Shell Extension wrote JSONs before UI attached listener.
      File(
        p.join(tempQueueDir.path, 'shell_0002.json'),
      ).writeAsStringSync(jsonEncode([r'E:\second.zip']), flush: true);
      File(
        p.join(tempQueueDir.path, 'shell_0001.json'),
      ).writeAsStringSync(jsonEncode([r'E:\first.zip']), flush: true);
      // Corrupt file must be discarded cleanly without blocking valid batches.
      File(
        p.join(tempQueueDir.path, 'shell_0000_bad.json'),
      ).writeAsStringSync('{not-valid-json', flush: true);

      DesktopIntegrationService.debugStartQueueWatcher(tempQueueDir.path);
      await DesktopIntegrationService.debugDrainQueue(tempQueueDir.path);

      final flushed = <List<String>>[];
      final sub = DesktopIntegrationService.fileStream.listen(flushed.add);
      try {
        DesktopIntegrationService.flushPendingArgs();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(flushed, hasLength(1));
        expect(flushed.first, [r'E:\first.zip', r'E:\second.zip']);
        expect(tempQueueDir.listSync(), isEmpty);
      } finally {
        await sub.cancel();
      }
    },
  );
}
