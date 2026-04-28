import 'dart:io';
import 'dart:convert';
import 'dart:ui';
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

  /// Sends a file or folder to the receiver at [targetIp].
  ///
  /// Calls [onUpdate] with progress updates and [onDone] when finished.
  Future<void> sendData({
    required String path,
    required String targetIp,
    required bool isFolder,
    required Function(TransferModel) onUpdate,
    required VoidCallback onDone,
  }) async {
    Stopwatch stopwatch = Stopwatch()..start();
    try {
      onUpdate(TransferModel(status: "Analyzing Files..."));

      List<Map<String, dynamic>> fileList = [];
      int totalBytesToSend = 0;

      if (isFolder) {
        var dir = Directory(path);
        if (!dir.existsSync()) throw "Folder not found!";

        var entities = dir.listSync(recursive: true).whereType<File>();
        for (var f in entities) {
          int size = f.lengthSync();
          // Normalize path separators for cross-platform compatibility
          String normalizedPath = p
              .relative(f.path, from: p.dirname(path))
              .replaceAll(r'\', '/');
          fileList.add({
            "path": normalizedPath,
            "size": size,
            "absPath": f.path,
          });
          totalBytesToSend += size;
        }
      } else {
        var f = File(path);
        if (!f.existsSync()) throw "File not found!";
        int size = f.lengthSync();
        fileList.add({
          "path": p.basename(path),
          "size": size,
          "absPath": f.path,
        });
        totalBytesToSend += size;
      }

      if (totalBytesToSend == 0) {
        throw "Error: The selected item is empty (0.0 MB).";
      }

      // Connect to receiver
      onUpdate(TransferModel(status: "Connecting..."));
      final socket = await Socket.connect(
        targetIp,
        AppConstants.transferPort,
        timeout: const Duration(seconds: AppConstants.connectionTimeoutSeconds),
      );
      _activeSocket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);

      // Send file metadata (JSON header)
      String originalName = isFolder ? p.basename(path) : p.basename(path);
      Map<String, dynamic> metadata = {
        "fileName": originalName,
        "fileSize": totalBytesToSend,
        "isFolder": isFolder,
        "files": fileList
            .map((e) => {"path": e["path"], "size": e["size"]})
            .toList(),
      };

      try {
        String header = "${jsonEncode(metadata)}\n";
        socket.write(header);
        await socket.flush();
      } on SocketException {
        throw "Connection lost before sending data. Please check Wi-Fi.";
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
                    readyCompleter.completeError(
                      "Transfer Rejected by Receiver.",
                    );
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
      int sentBytes = 0;
      DateTime lastUpdate = DateTime.now();
      int bytesSinceUpdate = 0;

      for (var f in fileList) {
        File fileToRead = File(f["absPath"]);
        final reader = fileToRead.openRead();

        try {
          await for (var chunk in reader) {
            try {
              socket.add(chunk);
              await socket.flush(); // Prevent OOM by awaiting buffer flush
            } on SocketException {
              throw "Network disconnected during transfer.";
            }
            sentBytes += chunk.length;
            bytesSinceUpdate += chunk.length;

            if (DateTime.now().difference(lastUpdate).inMilliseconds >
                AppConstants.speedUpdateIntervalMs) {
              double speed = (bytesSinceUpdate / 1024 / 1024) / 0.5;
              onUpdate(
                TransferModel(
                  speed: speed,
                  transferred: sentBytes / 1024 / 1024,
                  fileName: p.basename(f["path"]),
                  status: "Pumping Data...",
                  progress: totalBytesToSend > 0
                      ? sentBytes / totalBytesToSend
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
      double finalMB = totalBytesToSend / 1024 / 1024;
      double avg = finalMB / (stopwatch.elapsedMilliseconds / 1000);

      // Wait for DONE status with timeout
      onUpdate(
        TransferModel(
          status: "Finalizing transfer... Please wait for disk write.",
          fileName: originalName,
          speed: 0,
          transferred: finalMB,
          avgSpeed: avg.toStringAsFixed(2),
        ),
      );

      try {
        await doneCompleter.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            if (sentBytes >= totalBytesToSend) {
              return; // Ignore timeout if all bytes were sent
            }
            throw "Timeout waiting for Receiver to finalize disk write.";
          },
        );
      } catch (e) {
        if (sentBytes < totalBytesToSend) {
          rethrow;
        }
      }

      await socket.close();

      onUpdate(
        TransferModel(
          status: "SUCCESSFULLY SENT!",
          transferred: finalMB,
          avgSpeed: avg.toStringAsFixed(2),
          totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1),
          fileName: isFolder ? p.basename(path) : fileList.first["path"],
        ),
      );
      onDone();
    } catch (e) {
      if (_isCancelled) {
        onUpdate(TransferModel(status: "Transfer Cancelled"));
      } else if (e is SocketException) {
        onUpdate(TransferModel(status: _mapSocketError(e)));
      } else if (e is TimeoutException) {
        onUpdate(
          TransferModel(
            status:
                "Device not found. Please double-check the IP address and ensure both devices are on the exact same Wi-Fi/Hotspot.",
          ),
        );
      } else {
        onUpdate(TransferModel(status: "Error: $e"));
      }
      onDone();
    } finally {
      _activeSocket = null;
      _isCancelled = false;
    }
  }

  /// Cancels an active send operation.
  void cancel() {
    _isCancelled = true;
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
        msg.contains("network is unreachable")) {
      return "No network connection. Please turn on Wi-Fi or connect to the Hotspot.";
    } else if (osError == 104 ||
        osError == 10054 ||
        osError == 32 ||
        msg.contains("connection reset by peer")) {
      return "Transfer cancelled by the other device.";
    } else {
      return "Network Error: Please ensure Wi-Fi is connected.";
    }
  }
}
