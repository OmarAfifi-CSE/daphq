import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:path/path.dart' as p;
import '../models/transfer_model.dart';
import '../core/app_constants.dart';

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
  }) async {
    _isCancelled = false;
    _cancelReason = null;
    _wasRejectedByReceiver = false;
    _currentTargetDeviceName = targetDeviceName;
    Socket? socket;
    Stopwatch stopwatch = Stopwatch()..start();
    int sentBytes = 0;
    double totalSizeBytes = 0;
    String? originalName;
    try {
      onUpdate(TransferModel(status: "Analyzing Files..."));

      // 1. Prepare file list from multiple paths
      List<Map<String, dynamic>> fileList = [];

      for (String path in paths) {
        if (await FileSystemEntity.isDirectory(path)) {
          final dir = Directory(path);
          await for (var entity in dir.list(recursive: true)) {
            if (entity is File) {
              final relPath = p
                  .relative(entity.path, from: dir.parent.path)
                  .replaceAll(r'\', '/');
              final size = await entity.length();
              fileList.add({
                "absPath": entity.path,
                "path": relPath,
                "size": size,
              });
              totalSizeBytes += size;
            }
          }
        } else {
          final file = File(path);
          final size = await file.length();
          final fileName = p.basename(file.path);
          fileList.add({"absPath": file.path, "path": fileName, "size": size});
          totalSizeBytes += size;
        }
      }

      if (fileList.isEmpty) throw "No files found in selection.";

      if (totalSizeBytes == 0) {
        throw "Error: The selected item is empty (0.0 MB).";
      }

      // Connect to receiver
      onUpdate(TransferModel(status: "Connecting..."));
      socket = await Socket.connect(
        targetIp,
        AppConstants.transferPort,
        timeout: const Duration(seconds: AppConstants.connectionTimeoutSeconds),
      );
      _activeSocket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);

      // Send file metadata (JSON header)
      originalName = paths.length == 1
          ? p.basename(paths[0])
          : "${p.basename(paths[0])} and ${paths.length - 1} more";

      Map<String, dynamic> metadata = {
        "fileName": originalName,
        "fileSize": totalSizeBytes,
        "senderDeviceName": senderDeviceName,
        "isFolder":
            paths.length > 1 || FileSystemEntity.isDirectorySync(paths[0]),
        "files": fileList
            .map((e) => {"path": e["path"], "size": e["size"]})
            .toList(),
      };

      try {
        String header = "${jsonEncode(metadata)}\n";
        socket.write(header);
        await socket.flush();
      } on SocketException {
        throw "Connection lost before sending data. Please check network/Hotspot.";
      }

      // Set up listeners for Receiver responses (READY and DONE)
      Completer<Map<String, dynamic>> readyCompleter = Completer();
      Completer<void> doneCompleter = Completer();
      String headerBuffer = "";

      socket.listen(
        (data) {
          headerBuffer += utf8.decode(data);
          while (headerBuffer.contains('\n')) {
            int newlineIndex = headerBuffer.indexOf('\n');
            String line = headerBuffer.substring(0, newlineIndex).trim();
            headerBuffer = headerBuffer.substring(newlineIndex + 1);

            if (line.isNotEmpty) {
              try {
                Map<String, dynamic> response = jsonDecode(line);
                if (response["status"] == "REJECTED") {
                  if (!readyCompleter.isCompleted) {
                    String errorMsg = response["reason"] == "OUT_OF_SPACE"
                        ? "Receiver has insufficient storage space."
                        : "Transfer rejected by ${_currentTargetDeviceName ?? 'Receiver'}";
                    readyCompleter.completeError(errorMsg);
                  } else {
                    // If already transferring, trigger a cancellation
                    String errorMsg = response["reason"] == "OUT_OF_SPACE"
                        ? "Receiver has insufficient storage space."
                        : "Transfer rejected by ${_currentTargetDeviceName ?? 'Receiver'}";
                    _isCancelled = true;
                    _wasRejectedByReceiver = true;
                    _cancelReason = errorMsg;
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
      onUpdate(TransferModel(status: "Waiting for Receiver to Accept..."));
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

      // Stream file data
      DateTime lastUpdate = DateTime.now();
      int bytesSinceUpdate = 0;
      int bytesBuffered = 0;

      for (var f in fileList) {
        if (_isCancelled) throw "Transfer Cancelled";
        File fileToRead = File(f["absPath"]);
        final reader = fileToRead.openRead();

        try {
          await for (var chunk in reader) {
            if (_isCancelled) throw "Transfer Cancelled";
            try {
              if (_isCancelled) throw "Transfer Cancelled";
              socket.add(chunk);
              bytesBuffered += chunk.length;
              if (bytesBuffered >= AppConstants.socketFlushThresholdBytes) {
                await socket.flush().timeout(
                  const Duration(seconds: AppConstants.transferTimeoutSeconds),
                  onTimeout: () => throw "Transfer Timeout",
                ); // Prevent OOM by awaiting buffer flush
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

            if (DateTime.now().difference(lastUpdate).inMilliseconds >
                AppConstants.speedUpdateIntervalMs) {
              double speed =
                  (bytesSinceUpdate / 1024 / 1024) /
                  (AppConstants.speedUpdateIntervalMs / 1000);
              onUpdate(
                TransferModel(
                  speed: speed,
                  transferred: sentBytes / 1024 / 1024,
                  fileName: p.basename(f["path"]),
                  status: "Pumping Data...",
                  totalSize: totalSizeBytes / 1024 / 1024,
                  progress: totalSizeBytes > 0
                      ? sentBytes / totalSizeBytes
                      : 0.0,
                ),
              );
              bytesSinceUpdate = 0;
              lastUpdate = DateTime.now();
            }
          }
        } finally {}
      }

      await socket.flush();

      // Stop the stopwatch immediately after bytes are sent for accurate speed
      stopwatch.stop();
      double finalMB = totalSizeBytes / 1024 / 1024;
      double avg = finalMB / (stopwatch.elapsedMilliseconds / 1000);

      // Wait for DONE status with timeout
      onUpdate(
        TransferModel(
          status: "Finalizing... Saving to disk",
          fileName: originalName,
          speed: 0,
          transferred: finalMB,
          totalSize: finalMB,
          avgSpeed: avg.toStringAsFixed(2),
          progress: 1.0,
        ),
      );

      try {
        await doneCompleter.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            if (sentBytes >= totalSizeBytes) {
              return; // Ignore timeout if all bytes were sent
            }
            throw "Timeout waiting for Receiver to finalize disk write.";
          },
        );
      } catch (e) {
        // If the receiver cancelled/rejected during the finalization phase, we should still report it
        if (_isCancelled) throw "Transfer Cancelled";

        if (sentBytes < totalSizeBytes) {
          rethrow;
        }
      }

      await socket.close();

      onUpdate(
        TransferModel(
          status: "Transfer Complete!",
          transferred: finalMB,
          totalSize: finalMB,
          avgSpeed: avg.toStringAsFixed(2),
          totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1),
          fileName: paths.length == 1 ? p.basename(paths[0]) : "Multiple Items",
          progress: 1.0,
        ),
      );
    } on PathAccessException {
      onUpdate(TransferModel(status: "Error: Permission Denied"));
    } catch (e) {
      if (_isCancelled || e.toString().contains("Transfer Cancelled")) {
        String status = _wasRejectedByReceiver
            ? "Transfer cancelled by ${_currentTargetDeviceName ?? 'Receiver'}"
            : _cancelReason ?? "Transfer Cancelled";
        onUpdate(
          TransferModel(
            status: status,
            transferred: sentBytes / 1024 / 1024,
            totalSize: totalSizeBytes / 1024 / 1024,
            progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
            fileName: originalName ?? "",
          ),
        );
      } else if (e.toString().contains("Receiver disconnected") ||
          e.toString().contains("Transfer Timeout")) {
        onUpdate(
          TransferModel(
            status:
                "Transfer cancelled by ${_currentTargetDeviceName ?? 'the other device'}",
            transferred: sentBytes / 1024 / 1024,
            totalSize: totalSizeBytes / 1024 / 1024,
            progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
            fileName: originalName ?? "",
          ),
        );
      } else if (e is SocketException) {
        onUpdate(
          TransferModel(
            status: _mapSocketError(e),
            transferred: sentBytes / 1024 / 1024,
            totalSize: totalSizeBytes / 1024 / 1024,
            progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
            fileName: originalName ?? "",
          ),
        );
      } else if (e is TimeoutException) {
        onUpdate(
          TransferModel(
            status:
                "Device not found. Please double-check the IP address and ensure both devices are on the exact same Wi-Fi/Hotspot.",
            transferred: sentBytes / 1024 / 1024,
            totalSize: totalSizeBytes / 1024 / 1024,
            progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
            fileName: originalName ?? "",
          ),
        );
      } else {
        onUpdate(
          TransferModel(
            status: "Error: $e",
            transferred: sentBytes / 1024 / 1024,
            totalSize: totalSizeBytes / 1024 / 1024,
            progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
            fileName: originalName ?? "",
          ),
        );
      }
    } finally {
      _activeSocket = null;
      _isCancelled = false;
    }
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
