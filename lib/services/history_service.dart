import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class HistoryEntry {
  final String id;
  final String fileName;
  final double fileSizeMB;
  final String direction; // 'send' or 'receive'
  final String status; // 'success', 'failed', 'cancelled'
  final int timestamp;
  final String? localPath;

  HistoryEntry({
    required this.id,
    required this.fileName,
    required this.fileSizeMB,
    required this.direction,
    required this.status,
    required this.timestamp,
    this.localPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'fileSizeMB': fileSizeMB,
        'direction': direction,
        'status': status,
        'timestamp': timestamp,
        'localPath': localPath,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        fileSizeMB: (json['fileSizeMB'] as num).toDouble(),
        direction: json['direction'] as String,
        status: json['status'] as String,
        timestamp: json['timestamp'] as int,
        localPath: json['localPath'] as String?,
      );

  String get formattedDate {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1 && date.day == now.day) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays < 2 && date.day == now.subtract(const Duration(days: 1)).day) {
      return 'Yesterday';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  String get formattedSize {
    if (fileSizeMB >= 1024) {
      return "${(fileSizeMB / 1024).toStringAsFixed(2)} GB";
    } else {
      return "${fileSizeMB.toStringAsFixed(1)} MB";
    }
  }
}

class HistoryEntryInput {
  final String fileName;
  final double fileSizeMB;
  final String direction;
  final String status;
  final String? localPath;

  HistoryEntryInput({
    required this.fileName,
    required this.fileSizeMB,
    required this.direction,
    required this.status,
    this.localPath,
  });
}

class HistoryService {
  static const int _maxHistoryItems = 2000;
  static Future<void> _writeQueue = Future<void>.value();

  @visibleForTesting
  static Future<Directory> Function()? directoryProvider;

  static Future<T> _enqueue<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static Future<File> _getFile() async {
    final dir = await (directoryProvider ?? getApplicationSupportDirectory)();
    final file = File('${dir.path}/daphq_history.json');
    if (!await file.exists()) {
      await file.create(recursive: true);
      await file.writeAsString(jsonEncode([]));
    }
    return file;
  }

  static Future<List<HistoryEntry>> _readEntriesUnlocked() async {
    final file = await _getFile();
    final content = await file.readAsString();
    final List<dynamic> decoded = jsonDecode(content);
    return decoded
        .map((item) => HistoryEntry.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  static Future<void> _writeEntriesUnlocked(List<HistoryEntry> entries) async {
    final file = await _getFile();
    final tmpFile = File('${file.path}.tmp');
    final encoded = jsonEncode(entries.map((e) => e.toJson()).toList());
    await tmpFile.writeAsString(encoded, flush: false);
    if (await file.exists()) {
      await tmpFile.rename(file.path);
    } else {
      await tmpFile.rename(file.path);
    }
  }

  /// Load all history entries
  static Future<List<HistoryEntry>> loadHistory() async {
    try {
      return await _readEntriesUnlocked();
    } catch (_) {
      return [];
    }
  }

  /// Add multiple entries atomically through the serialized write queue
  static Future<void> addEntries(List<HistoryEntryInput> inputs) async {
    if (inputs.isEmpty) return;
    await _enqueue(() async {
      try {
        List<HistoryEntry> history;
        try {
          history = await _readEntriesUnlocked();
        } catch (_) {
          history = [];
        }
        final now = DateTime.now().millisecondsSinceEpoch;

        final List<HistoryEntry> newEntries = [];
        for (int i = 0; i < inputs.length; i++) {
          final input = inputs[i];
          newEntries.add(
            HistoryEntry(
              id: "${now}_${i}_${input.fileName.hashCode}",
              fileName: input.fileName,
              fileSizeMB: input.fileSizeMB,
              direction: input.direction,
              status: input.status,
              timestamp: now - i, // Offset slightly to guarantee sorted order
              localPath: input.localPath,
            ),
          );
        }

        // Add all to the beginning of the list
        history.insertAll(0, newEntries);

        // Enforce max item limit
        if (history.length > _maxHistoryItems) {
          history.removeRange(_maxHistoryItems, history.length);
        }

        await _writeEntriesUnlocked(history);
      } catch (_) {}
    });
  }

  /// Add a single entry to the history log
  static Future<void> addEntry({
    required String fileName,
    required double fileSizeMB,
    required String direction,
    required String status,
    String? localPath,
  }) async {
    await addEntries([
      HistoryEntryInput(
        fileName: fileName,
        fileSizeMB: fileSizeMB,
        direction: direction,
        status: status,
        localPath: localPath,
      )
    ]);
  }

  /// Clear the entire transfer history log
  static Future<void> clearHistory() async {
    await _enqueue(() async {
      try {
        await _writeEntriesUnlocked([]);
      } catch (_) {}
    });
  }
}
