import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:daphq/services/history_service.dart';

void main() {
  group('HistoryService serialized persistence', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('daphq_history_test_');
      HistoryService.directoryProvider = () async => tempDir;
    });

    tearDown(() async {
      HistoryService.directoryProvider = null;
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('preserves all entries when concurrent addEntries calls overlap', () async {
      await Future.wait([
        HistoryService.addEntries([
          HistoryEntryInput(
            fileName: 'send_1.bin',
            fileSizeMB: 1.5,
            direction: 'send',
            status: 'success',
          ),
        ]),
        HistoryService.addEntries([
          HistoryEntryInput(
            fileName: 'recv_1.bin',
            fileSizeMB: 2.5,
            direction: 'receive',
            status: 'success',
          ),
        ]),
        HistoryService.addEntries([
          HistoryEntryInput(
            fileName: 'send_2.bin',
            fileSizeMB: 0.5,
            direction: 'send',
            status: 'cancelled',
          ),
        ]),
      ]);

      final history = await HistoryService.loadHistory();
      expect(history.length, 3);
      expect(
        history.map((e) => e.fileName).toSet(),
        containsAll(['send_1.bin', 'recv_1.bin', 'send_2.bin']),
      );
    });

    test('clearHistory resets log cleanly', () async {
      await HistoryService.addEntry(
        fileName: 'a.txt',
        fileSizeMB: 0.1,
        direction: 'send',
        status: 'success',
      );
      expect((await HistoryService.loadHistory()).length, 1);

      await HistoryService.clearHistory();
      expect(await HistoryService.loadHistory(), isEmpty);
    });
  });
}

