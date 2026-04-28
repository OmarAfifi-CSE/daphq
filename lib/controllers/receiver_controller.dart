import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../models/transfer_model.dart';
import '../core/app_constants.dart';

/// Handles the receiver side of the file transfer protocol.
///
/// Binds a TCP server, accepts incoming connections, parses the JSON metadata
/// header, requests user authorization, then writes incoming bytes to disk.
class ReceiverController {
  ServerSocket? _server;
  Socket? _activeClient;
  IOSink? _activeSink;
  bool _isCancelled = false;

  /// Starts a TCP server and waits for incoming file transfers.
  ///
  /// [saveDirectory] is the folder where received files will be saved.
  /// [onRequestAuth] is called to ask the user whether to accept a transfer.
  Future<void> startReceiver({
    required String saveDirectory,
    required Function(TransferModel) onUpdate,
    required Future<bool> Function(
      String senderIp,
      int fileCount,
      double totalSizeMB,
    )
    onRequestAuth,
    required VoidCallback onDone,
  }) async {
    try {
      if (_server != null) await _server!.close();
      try {
        _server = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          AppConstants.transferPort,
          shared: true,
        );
      } on SocketException catch (e) {
        throw "Could not bind server. Are you connected to Wi-Fi? (${e.message})";
      }
      onUpdate(
        TransferModel(
          status: "Receiver Ready (Port: ${AppConstants.transferPort})",
        ),
      );

      await for (Socket client in _server!) {
        _activeClient = client;
        try {
          Stopwatch stopwatch = Stopwatch()..start();
          bool isRejected = false;

          List<int> headerBuffer = [];
          Map<String, dynamic>? metadata;

          int currentFileIndex = 0;
          int bytesReadForCurrentFile = 0;
          IOSink? currentSink;

          int received = 0;
          int bytesSinceUpdate = 0;
          DateTime lastTime = DateTime.now();

          await for (var chunk in client) {
            int offset = 0;

            // Parse JSON header
            if (metadata == null) {
              int newlineIndex = chunk.indexOf(10); // \n
              if (newlineIndex != -1) {
                headerBuffer.addAll(chunk.sublist(0, newlineIndex));
                String jsonStr = utf8.decode(headerBuffer);
                metadata = jsonDecode(jsonStr);

                offset = newlineIndex + 1;

                // Authorization step
                List<dynamic> files = metadata!["files"];
                int totalBytes = files.fold(
                  0,
                  (sum, f) => sum + (f["size"] as int),
                );
                double totalSizeMB = totalBytes / 1024 / 1024;

                bool isAccepted = await onRequestAuth(
                  client.remoteAddress.address,
                  files.length,
                  totalSizeMB,
                );

                if (!isAccepted) {
                  try {
                    client.write("${jsonEncode({"status": "REJECTED"})}\n");
                    await client.flush();
                  } catch (_) {}
                  client.destroy();
                  isRejected = true;
                  onUpdate(
                    TransferModel(
                      status: "Transfer Rejected. Ready & Waiting...",
                    ),
                  );
                  break;
                } else {
                  try {
                    // Calculate resume offsets for partially received files
                    Map<String, int> offsets = {};
                    for (var fMeta in files) {
                      File localF = File(p.join(saveDirectory, fMeta["path"]));
                      if (localF.existsSync()) {
                        int len = localF.lengthSync();
                        if (len <= fMeta["size"]) {
                          offsets[fMeta["path"]] = len;
                        } else {
                          localF.deleteSync();
                        }
                      }
                    }

                    client.write(
                      "${jsonEncode({"status": "ACCEPTED", "offsets": offsets})}\n",
                    );
                    await client.flush();
                  } catch (_) {
                    throw "Sender disconnected before starting.";
                  }
                }
              } else {
                headerBuffer.addAll(chunk);
                continue;
              }
            }

            List<dynamic> files = metadata["files"];
            try {
              while (offset < chunk.length && currentFileIndex < files.length) {
                var fileMeta = files[currentFileIndex];
                int targetSize = fileMeta["size"];

                // Open file for writing if not already open
                if (currentSink == null) {
                  String savePath = p.join(saveDirectory, fileMeta["path"]);
                  File f = File(savePath);
                  // Create subdirectories recursively
                  f.parent.createSync(recursive: true);

                  int existingLen = f.existsSync() ? f.lengthSync() : 0;
                  if (existingLen > targetSize) {
                    f.deleteSync();
                    existingLen = 0;
                  }

                  currentSink = f.openWrite(mode: FileMode.append);
                  _activeSink = currentSink;
                  bytesReadForCurrentFile = existingLen;
                  if (received == 0) {
                    // Add offsets of current + all previously skipped files to received
                    int totalExisting = 0;
                    for (int i = 0; i <= currentFileIndex; i++) {
                      File tmp = File(p.join(saveDirectory, files[i]["path"]));
                      if (tmp.existsSync()) totalExisting += tmp.lengthSync();
                    }
                    received += totalExisting;
                  }
                }

                int remainingInChunk = chunk.length - offset;
                int bytesNeeded = targetSize - bytesReadForCurrentFile;

                if (bytesNeeded <= 0) {
                  // Already complete file from previous session
                  await currentSink.flush();
                  await currentSink.close();
                  currentSink = null;
                  bytesReadForCurrentFile = 0;
                  currentFileIndex++;
                  continue;
                }

                // Write bytes with exact boundary precision
                if (remainingInChunk <= bytesNeeded) {
                  currentSink.add(Uint8List.sublistView(chunk as Uint8List, offset));
                  bytesReadForCurrentFile += remainingInChunk;
                  received += remainingInChunk;
                  bytesSinceUpdate += remainingInChunk;
                  offset += remainingInChunk;
                } else {
                  currentSink.add(Uint8List.sublistView(chunk as Uint8List, offset, offset + bytesNeeded));
                  bytesReadForCurrentFile += bytesNeeded;
                  received += bytesNeeded;
                  bytesSinceUpdate += bytesNeeded;
                  offset += bytesNeeded;
                }

                // Update speed in UI
                if (DateTime.now().difference(lastTime).inMilliseconds >
                    AppConstants.speedUpdateIntervalMs) {
                  double speed = (bytesSinceUpdate / 1024 / 1024) / 0.5;
                  onUpdate(
                    TransferModel(
                      speed: speed,
                      transferred: received / 1024 / 1024,
                      fileName: p.basename(fileMeta["path"]),
                      status: "Receiving Data...",
                    ),
                  );
                  bytesSinceUpdate = 0;
                  lastTime = DateTime.now();
                }

                // Close file when fully received
                if (bytesReadForCurrentFile == targetSize) {
                  await currentSink.flush();
                  await currentSink.close();
                  currentSink = null;
                  _activeSink = null;
                  bytesReadForCurrentFile = 0;
                  currentFileIndex++;
                }
              }
            } finally {
              if (currentSink != null && currentFileIndex >= files.length) {
                await currentSink.flush();
                await currentSink.close();
                _activeSink = null;
              }
            }
          } // end await for chunk

          if (isRejected) {
            continue;
          }

          if (_isCancelled) {
            throw "Transfer Cancelled";
          }

          // Final cleanup for any streams left open
          if (currentSink != null) {
            await currentSink.flush();
            await currentSink.close();
            currentSink = null;
            _activeSink = null;
          }

          // Check for premature connection drop
          int totalExpectedBytes =
              metadata?["files"]?.fold(
                0,
                (sum, f) => sum + (f["size"] as int),
              ) ??
              0;
          if (metadata != null && received < totalExpectedBytes) {
            throw "Connection dropped prematurely.";
          }

          stopwatch.stop();
          double finalMB = received / 1024 / 1024;

          onUpdate(
            TransferModel(
              status: "Transfer Complete! Ready & Waiting...",
              transferred: finalMB,
              avgSpeed: (finalMB / (stopwatch.elapsedMilliseconds / 1000))
                  .toStringAsFixed(2),
              totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(
                1,
              ),
              fileName: "All files saved.",
            ),
          );
        } catch (e) {
          if (_isCancelled) {
            onUpdate(
              TransferModel(status: "Transfer Cancelled. Ready & Waiting..."),
            );
          } else if (e is SocketException) {
            onUpdate(TransferModel(status: _mapReceiverSocketError(e)));
          } else {
            onUpdate(TransferModel(status: "Error: $e. Ready & Waiting..."));
          }
        } finally {
          try {
            client.destroy();
          } catch (_) {}
          _activeClient = null;
          _activeSink = null;
        }
      }
    } catch (e) {
      if (_isCancelled) {
        onUpdate(TransferModel(status: "Transfer Cancelled"));
      } else if (e is SocketException) {
        final msg = e.message.toLowerCase();
        final osError = e.osError?.errorCode;
        if (osError == 104 ||
            osError == 10054 ||
            osError == 32 ||
            msg.contains("connection reset by peer")) {
          onUpdate(
            TransferModel(status: "Transfer cancelled by the other device."),
          );
        } else {
          onUpdate(
            TransferModel(
              status: "Network Error: Please check Wi-Fi connection.",
            ),
          );
        }
      } else {
        onUpdate(TransferModel(status: "Error: $e"));
      }
      onDone();
    } finally {
      _activeClient = null;
      _activeSink = null;
      _isCancelled = false;
    }
  }

  /// Stops the receiver server and cancels any active transfer.
  void stop() {
    _isCancelled = true;
    _server?.close();
    _server = null;

    _activeSink?.close();
    _activeSink = null;

    _activeClient?.destroy();
    _activeClient = null;
  }

  /// Maps a [SocketException] to a user-friendly error message for receiver.
  String _mapReceiverSocketError(SocketException e) {
    final msg = e.message.toLowerCase();
    final osError = e.osError?.errorCode;
    if (osError == 104 ||
        osError == 10054 ||
        osError == 32 ||
        msg.contains("connection reset by peer")) {
      return "Transfer cancelled by the other device. Ready & Waiting...";
    } else {
      return "Network Error: Please check Wi-Fi connection. Ready & Waiting...";
    }
  }
}
