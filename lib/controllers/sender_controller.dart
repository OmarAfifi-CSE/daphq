import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as p;
import '../models/transfer_model.dart';
import '../core/app_constants.dart';

/// Typed exception thrown by [SenderController.sendData] carrying the
/// user-facing message and machine-readable terminal [TransferPhase].
class TransferSendException implements Exception {
  final String message;
  final TransferPhase phase;

  const TransferSendException(this.message, this.phase);

  @override
  String toString() => message;
}

/// Handles the sender side of the file transfer protocol.
///
/// Connects to a receiver, sends a JSON metadata header describing the files,
/// waits for authorization, then streams raw file bytes over TCP.
class SenderController {
  Socket? _activeSocket;
  bool _isCancelled = false;
  String? _cancelReason;
  bool _wasRejectedByReceiver = false;
  String? _currentTargetDeviceName;

  /// Sends a file or folder to the receiver at [targetIp].
  ///
  /// Calls [onUpdate] with progress updates and [onDone] when finished.
  Future<void> sendData({
    required List<String> paths,
    required String targetIp,
    required String targetDeviceName,
    required String senderDeviceName,
    required Function(TransferModel) onUpdate,
    int port = AppConstants.transferPort,
  }) async {
    _isCancelled = false;
    _cancelReason = null;
    _wasRejectedByReceiver = false;
    _currentTargetDeviceName = targetDeviceName;
    Socket? socket;
    StreamSubscription<dynamic>? socketSub;
    final Stopwatch stopwatch = Stopwatch();
    int sentBytes = 0;
    double totalSizeBytes = 0;
    String? originalName;
    try {
      onUpdate(
        TransferModel(
          status: "Analyzing Files...",
          analyzeCount: 0,
          phase: TransferPhase.analyzing,
        ),
      );

      // 1. Prepare file list from multiple paths
      List<Map<String, dynamic>> fileList = [];

      int discoveredCount = 0;

      // Flush a batch of files by calling entity.length() in parallel.
      // This keeps Dart's I/O isolate pool busy instead of waiting serially.
      Future<void> flushBatch(List<File> batch, String fromPath) async {
        if (_isCancelled) return;
        final results = await Future.wait(
          batch.map((f) async {
            try {
              final size = await f.length();
              final relPath = p
                  .relative(f.path, from: fromPath)
                  .replaceAll(r'\', '/');
              return <String, dynamic>{
                "absPath": f.path,
                "path": relPath,
                "size": size,
              };
            } catch (_) {
              return null; // Skip locked/protected files
            }
          }),
        );
        for (final r in results) {
          if (r != null) {
            fileList.add(r);
            totalSizeBytes += r["size"] as int;
          }
        }
      }

      for (String path in paths) {
        if (_isCancelled) break;
        if (await FileSystemEntity.isDirectory(path)) {
          final dir = Directory(path);
          final fromPath = dir.parent.path;
          const int batchSize = 64;
          List<File> batch = [];

          await for (var entity
              in dir
                  .list(recursive: true, followLinks: false)
                  .handleError((_) {})) {
            if (_isCancelled) break; // Stop listing immediately on cancel
            if (entity is File) {
              batch.add(entity);
              discoveredCount++;

              // Update the file count every 50 files so the user sees
              // live progress on slow devices with large directories.
              if (discoveredCount % 50 == 0) {
                onUpdate(
                  TransferModel(
                    status: "Analyzing...",
                    analyzeCount: discoveredCount,
                    phase: TransferPhase.analyzing,
                  ),
                );
              }

              if (batch.length >= batchSize) {
                await flushBatch(batch, fromPath);
                batch.clear();
              }
            }
          }
          if (!_isCancelled) {
            // Flush any remaining files in the last partial batch
            await flushBatch(batch, fromPath);
          }
        } else {
          final file = File(path);
          final size = await file.length();
          final fileName = p.basename(file.path);
          fileList.add({"absPath": file.path, "path": fileName, "size": size});
          totalSizeBytes += size;
        }
      }

      if (_isCancelled) throw "Transfer Cancelled";

      // Plan T-009: deduplicate collisions case-insensitively across the batch.
      deduplicateRelativePaths(fileList);

      if (fileList.isEmpty) throw "No files found in selection.";

      if (totalSizeBytes == 0) {
        throw "Error: The selected item is empty (0.0 MB).";
      }

      // Build the JSON header BEFORE connecting so we can validate its size
      // without disturbing the receiver.
      String resolveName(String path) {
        final base = p.basename(path);
        if (base.isEmpty || base == r'\' || base == '/') {
          return path.replaceAll(RegExp(r'[\\/]+$'), '');
        }
        return base;
      }

      originalName = paths.length == 1
          ? resolveName(paths[0])
          : "${resolveName(paths[0])} and ${paths.length - 1} more";

      final Map<String, dynamic> metadata = {
        "fileName": originalName,
        "fileSize": totalSizeBytes,
        "senderDeviceName": senderDeviceName,
        "isFolder":
            paths.length > 1 || FileSystemEntity.isDirectorySync(paths[0]),
        "files": fileList
            .map((e) => {"path": e["path"], "size": e["size"]})
            .toList(),
      };

      final String header = "${jsonEncode(metadata)}\n";

      // Pre-flight size check — fail before connecting so the receiver
      // is never disturbed.
      if (header.length > 32 * 1024 * 1024) {
        throw "Too many files selected (${fileList.length} files). "
            "The transfer metadata is too large. "
            "Please select a subfolder instead of the entire drive root.";
      }

      // Connect to receiver only after all validations pass
      onUpdate(
        TransferModel(
          status: "Connecting...",
          fileName: originalName,
          phase: TransferPhase.waitingAuth,
        ),
      );
      socket = await Socket.connect(
        targetIp,
        port,
        timeout: const Duration(seconds: AppConstants.connectionTimeoutSeconds),
      );
      _activeSocket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);

      // Send file metadata (JSON header)
      try {
        socket.write(header);
        await socket.flush();
      } on SocketException {
        throw "Connection lost before sending data. Please check network/Hotspot.";
      }

      // Set up listeners for Receiver responses (READY and DONE)
      final Completer<Map<String, dynamic>> readyCompleter = Completer();
      final Completer<void> doneCompleter = Completer();
      // Prevent unhandled zone errors if socket closes before await reaches these futures.
      readyCompleter.future.catchError((_) => <String, dynamic>{});
      doneCompleter.future.catchError((_) {});
      final List<int> responseBytes = [];

      socketSub = socket.listen(
        (data) {
          responseBytes.addAll(data);
          while (true) {
            final int newlineIndex = responseBytes.indexOf(10); // \n
            if (newlineIndex == -1) break;
            final String line = utf8
                .decode(responseBytes.sublist(0, newlineIndex), allowMalformed: true)
                .trim();
            responseBytes.removeRange(0, newlineIndex + 1);

            if (line.isNotEmpty) {
              try {
                final Map<String, dynamic> response = jsonDecode(line);
                if (response["status"] == "REJECTED") {
                  final reason = response["reason"];
                  final String errorMsg = reason == "OUT_OF_SPACE"
                      ? "Transfer rejected by ${_currentTargetDeviceName ?? 'Receiver'}: Insufficient storage space."
                      : reason == "HEADER_TOO_LARGE"
                      ? "Too many files — the transfer metadata is too large. Please select a subfolder instead."
                      : "Transfer rejected by ${_currentTargetDeviceName ?? 'Receiver'}.";
                  if (!readyCompleter.isCompleted) {
                    _wasRejectedByReceiver = true;
                    readyCompleter.completeError(errorMsg);
                  } else {
                    _isCancelled = true;
                    _wasRejectedByReceiver = true;
                    _cancelReason = errorMsg;
                    if (!doneCompleter.isCompleted) {
                      doneCompleter.completeError(errorMsg);
                    }
                    socket?.destroy();
                  }
                } else if (response["s"] == "r") {
                  if (!readyCompleter.isCompleted) {
                    readyCompleter.complete({});
                  }
                } else if (response["s"] == "d") {
                  if (!doneCompleter.isCompleted) {
                    doneCompleter.complete();
                  }
                }
              } catch (_) {}
            }
          }
        },
        onError: (e) {
          if (!readyCompleter.isCompleted) {
            readyCompleter.completeError("Receiver disconnected.");
          }
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError("Receiver disconnected.");
          }
        },
        onDone: () {
          if (!readyCompleter.isCompleted) {
            readyCompleter.completeError("Receiver disconnected.");
          }
          if (!doneCompleter.isCompleted) {
            doneCompleter.completeError("Receiver disconnected.");
          }
        },
        cancelOnError: true,
      );

      // Wait for authorization and readiness
      onUpdate(
        TransferModel(
          status: "Waiting for Receiver to Accept...",
          fileName: originalName,
          totalSize: totalSizeBytes / 1024 / 1024,
          phase: TransferPhase.waitingAuth,
        ),
      );
      try {
        await readyCompleter.future.timeout(
          const Duration(minutes: AppConstants.authTimeoutMinutes),
          onTimeout: () => throw "Timeout",
        );
      } catch (e) {
        if (e == "Timeout") {
          throw "Receiver disconnected or timeout before answering.";
        }
        rethrow;
      }

      // Measure speed from actual wire start (after user authorization)
      stopwatch.start();
      onUpdate(
        TransferModel(
          status: "Pumping Data...",
          fileName: originalName,
          totalSize: totalSizeBytes / 1024 / 1024,
          progress: 0.0,
          phase: TransferPhase.sending,
        ),
      );

      // Stream file data
      DateTime lastUpdate = DateTime.now();
      int bytesSinceUpdate = 0;
      int bytesBuffered = 0;

      for (var f in fileList) {
        if (_isCancelled) throw "Transfer Cancelled";
        final File fileToRead = File(f["absPath"] as String);
        final int fileSize = f["size"] as int;
        int bytesSentForFile = 0;

        if (fileSize <= 64 * 1024) {
          // Fast path for small files (<= 64KB): read completely into memory
          try {
            final bytes = await fileToRead.readAsBytes();
            if (_isCancelled) throw "Transfer Cancelled";
            if (bytes.length != fileSize) {
              throw "File '${p.basename(f["absPath"] as String)}' changed on disk during transfer.";
            }
            socket.add(bytes);
            bytesSentForFile = bytes.length;
            sentBytes += bytes.length;
            bytesSinceUpdate += bytes.length;
            bytesBuffered += bytes.length;

            if (bytesBuffered >= AppConstants.socketFlushThresholdBytes) {
              await socket.flush();
              bytesBuffered = 0;
            }
          } catch (e) {
            if (_isCancelled) throw "Transfer Cancelled";
            if (e is SocketException ||
                e.toString().contains("reset by peer")) {
              throw "Receiver disconnected during transfer.";
            }
            rethrow;
          }
        } else {
          // Standard path for larger files: stream in chunks
          final reader = fileToRead.openRead();
          try {
            await for (var chunk in reader) {
              if (_isCancelled) throw "Transfer Cancelled";
              bytesSentForFile += chunk.length;
              if (bytesSentForFile > fileSize) {
                throw "File '${p.basename(f["absPath"] as String)}' grew on disk during transfer.";
              }
              try {
                socket.add(chunk);
                bytesBuffered += chunk.length;
                if (bytesBuffered >= AppConstants.socketFlushThresholdBytes) {
                  await socket.flush();
                  bytesBuffered = 0;
                }
              } catch (e) {
                if (_isCancelled) throw "Transfer Cancelled";
                if (e is SocketException ||
                    e.toString().contains("reset by peer")) {
                  throw "Receiver disconnected during transfer.";
                }
                rethrow;
              }

              if (_isCancelled) throw "Transfer Cancelled";
              sentBytes += chunk.length;
              bytesSinceUpdate += chunk.length;

              // Trigger speed/progress UI update if needed inside the chunk streaming loop
              final now = DateTime.now();
              final elapsedMs = now.difference(lastUpdate).inMilliseconds;
              if (elapsedMs > AppConstants.speedUpdateIntervalMs) {
                final double speed =
                    (bytesSinceUpdate / 1024 / 1024) / (elapsedMs / 1000.0);
                onUpdate(
                  TransferModel(
                    speed: speed,
                    transferred: sentBytes / 1024 / 1024,
                    fileName: p.basename(f["path"] as String),
                    status: "Pumping Data...",
                    totalSize: totalSizeBytes / 1024 / 1024,
                    progress: totalSizeBytes > 0
                        ? sentBytes / totalSizeBytes
                        : 0.0,
                    phase: TransferPhase.sending,
                  ),
                );
                bytesSinceUpdate = 0;
                lastUpdate = now;
              }
            }
            if (bytesSentForFile != fileSize) {
              throw "File '${p.basename(f["absPath"] as String)}' changed on disk during transfer.";
            }
          } finally {}
        }

        // Trigger speed/progress UI update if needed
        final now = DateTime.now();
        final elapsedMs = now.difference(lastUpdate).inMilliseconds;
        if (elapsedMs > AppConstants.speedUpdateIntervalMs) {
          final double speed =
              (bytesSinceUpdate / 1024 / 1024) / (elapsedMs / 1000.0);
          onUpdate(
            TransferModel(
              speed: speed,
              transferred: sentBytes / 1024 / 1024,
              fileName: p.basename(f["path"] as String),
              status: "Pumping Data...",
              totalSize: totalSizeBytes / 1024 / 1024,
              progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
              phase: TransferPhase.sending,
            ),
          );
          bytesSinceUpdate = 0;
          lastUpdate = now;
        }
      }

      await socket.flush();

      // Stop the stopwatch immediately after payload bytes are flushed
      stopwatch.stop();
      final double finalMB = totalSizeBytes / 1024 / 1024;
      final double elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
      final double avg = elapsedSec > 0.001 ? (finalMB / elapsedSec) : 0.0;

      // Wait for receiver confirmation that disk finalize succeeded
      onUpdate(
        TransferModel(
          status: "Finalizing... Saving to disk",
          fileName: originalName,
          speed: 0,
          transferred: finalMB,
          totalSize: finalMB,
          avgSpeed: avg.toStringAsFixed(2),
          progress: 1.0,
          phase: TransferPhase.finalizing,
        ),
      );

      await doneCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw "Timeout waiting for Receiver to finalize disk write.";
        },
      );

      await socketSub.cancel();
      socketSub = null;
      await socket.close();

      onUpdate(
        TransferModel(
          status: "Transfer Complete!",
          transferred: finalMB,
          totalSize: finalMB,
          avgSpeed: avg.toStringAsFixed(2),
          totalTime: elapsedSec.toStringAsFixed(1),
          fileName: originalName,
          progress: 1.0,
          phase: TransferPhase.done,
        ),
      );
    } on PathAccessException catch (e) {
      final msg = "Error: $e";
      onUpdate(
        TransferModel(
          status: msg,
          fileName: originalName ?? "",
          phase: TransferPhase.failed,
        ),
      );
      throw TransferSendException(msg, TransferPhase.failed);
    } catch (e) {
      late final String terminalStatus;
      late final TransferPhase terminalPhase;

      if (_isCancelled || e.toString().contains("Transfer Cancelled")) {
        terminalStatus = _wasRejectedByReceiver
            ? (_cancelReason ??
                "Transfer cancelled by ${_currentTargetDeviceName ?? 'Receiver'}")
            : (_cancelReason ?? "Transfer Cancelled");
        terminalPhase = TransferPhase.cancelled;
      } else if (_wasRejectedByReceiver) {
        terminalStatus = e.toString();
        terminalPhase = TransferPhase.cancelled;
      } else if (e.toString().contains("Receiver disconnected") ||
          e.toString().contains("Transfer Timeout")) {
        terminalStatus =
            "Transfer cancelled by ${_currentTargetDeviceName ?? 'the other device'}";
        terminalPhase = TransferPhase.cancelled;
      } else if (e is SocketException) {
        terminalStatus = _mapSocketError(e);
        terminalPhase = _isCancelled || _isSocketPeerReset(e)
            ? TransferPhase.cancelled
            : TransferPhase.failed;
      } else if (e is TimeoutException) {
        terminalStatus =
            "Device not found. Please double-check the IP address and ensure both devices are on the exact same Wi-Fi/Hotspot.";
        terminalPhase = TransferPhase.failed;
      } else {
        terminalStatus = "Error: $e";
        terminalPhase = TransferPhase.failed;
      }

      onUpdate(
        TransferModel(
          status: terminalStatus,
          transferred: sentBytes / 1024 / 1024,
          totalSize: totalSizeBytes / 1024 / 1024,
          progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
          fileName: originalName ?? "",
          phase: terminalPhase,
        ),
      );
      throw TransferSendException(terminalStatus, terminalPhase);
    } finally {
      try {
        await socketSub?.cancel();
      } catch (_) {}
      try {
        socket?.destroy();
      } catch (_) {}
      _activeSocket = null;
      _isCancelled = false;
    }
  }

  /// Deduplicates relative metadata paths case-insensitively within a single batch
  /// (plan T-009) so case-insensitive filesystems (Windows/Android) never
  /// overwrite files like `Report.pdf` and `report.pdf`.
  static void deduplicateRelativePaths(List<Map<String, dynamic>> fileList) {
    final seenRelPathsLower = <String>{};
    for (final entry in fileList) {
      final rel = entry['path'] as String;
      if (seenRelPathsLower.add(rel.toLowerCase())) continue;
      final parentIndex = rel.lastIndexOf('/');
      final parent = parentIndex >= 0 ? rel.substring(0, parentIndex + 1) : '';
      final base = p.posix.basenameWithoutExtension(rel);
      final ext = p.posix.extension(rel);
      int counter = 1;
      String candidate;
      do {
        candidate = '$parent$base ($counter)$ext';
        counter++;
      } while (seenRelPathsLower.contains(candidate.toLowerCase()));
      entry['path'] = candidate;
      seenRelPathsLower.add(candidate.toLowerCase());
    }
  }

  static bool _isSocketPeerReset(SocketException e) {
    final osError = e.osError?.errorCode;
    return osError == 104 ||
        osError == 10054 ||
        osError == 32 ||
        e.message.toLowerCase().contains('connection reset by peer');
  }

  /// Cancels an active send operation.
  void cancel({String? reason}) {
    _isCancelled = true;
    _cancelReason = reason;
    _activeSocket?.destroy();
    _activeSocket = null;
  }

  /// Maps a [SocketException] to a user-friendly error message.
  String _mapSocketError(SocketException e) {
    final msg = e.message.toLowerCase();
    final osError = e.osError?.errorCode;

    if (osError == 111 ||
        osError == 10061 ||
        msg.contains("connection refused")) {
      return "Connection refused. Did the receiver click 'Start Receiving'?";
    } else if (osError == 113 ||
        osError == 112 ||
        osError == 10060 ||
        osError == 10065) {
      return "Device not found. Please double-check the IP address and ensure both devices are on the exact same Wi-Fi/Hotspot.";
    } else if (osError == 101 ||
        osError == 10051 ||
        osError == 10053 ||
        osError == 10050 ||
        msg.contains("network is unreachable") ||
        msg.contains("software caused connection abort")) {
      return "No network connection. Please turn on Wi-Fi/Hotspot.";
    } else if (osError == 104 ||
        osError == 10054 ||
        osError == 32 ||
        msg.contains("connection reset by peer")) {
      return "Transfer cancelled by ${_currentTargetDeviceName ?? 'the other device'}.";
    } else {
      return "Network Error: Please ensure network/Hotspot is connected.";
    }
  }
}
