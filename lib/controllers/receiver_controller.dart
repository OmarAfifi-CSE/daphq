import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'dart:typed_data';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:storage_space/storage_space.dart';
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
  String? _cancelReason;
  bool _isActiveTransferCancelled = false;
  String? _activeTransferCancelReason;
  String? _currentSenderDeviceName;
  Map<String, dynamic>? lastReceivedMetadata;

  /// Starts a TCP server and waits for incoming file transfers.
  ///
  /// [saveDirectory] is the folder where received files will be saved.
  /// [onRequestAuth] is called to ask the user whether to accept a transfer.
  Future<void> startReceiver({
    required String saveDirectory,
    required String deviceName,
    required Function(TransferModel) onUpdate,
    required Future<bool> Function(
      String senderIp,
      String senderDeviceName,
      int fileCount,
      double totalSizeMB,
    )
    onRequestAuth,
    required VoidCallback onDone,
  }) async {
    _isCancelled = false;
    _cancelReason = null;
    final Set<String> createdDirs = {};
    try {
      if (_server != null) {
        await _server!.close();
        _server = null;
        // Small delay to ensure OS releases the port
        await Future.delayed(const Duration(milliseconds: 200));
      }

      int attempts = 0;
      const int maxAttempts = 5;
      Object? lastError;

      while (attempts < maxAttempts && !_isCancelled) {
        onUpdate(
          TransferModel(
            status:
                "Initializing Server (Attempt ${attempts + 1}/$maxAttempts)...",
          ),
        );
        try {
          // Primary strategy: Bind to all interfaces (0.0.0.0)
          _server = await ServerSocket.bind(
            InternetAddress.anyIPv4,
            AppConstants.transferPort,
            shared: true,
          );
          break; // Success
        } catch (e) {
          lastError = e;

          // Fallback strategy: Try binding to specific available interfaces
          try {
            final interfaces = await NetworkInterface.list(
              type: InternetAddressType.IPv4,
            );
            for (var interface in interfaces) {
              for (var addr in interface.addresses) {
                if (!addr.isLoopback) {
                  try {
                    _server = await ServerSocket.bind(
                      addr,
                      AppConstants.transferPort,
                      shared: true,
                    );
                    if (_server != null) break;
                  } catch (_) {}
                }
              }
              if (_server != null) break;
            }
          } catch (_) {}

          if (_server != null) break; // Success via fallback

          attempts++;
          if (attempts < maxAttempts && !_isCancelled) {
            await Future.delayed(const Duration(seconds: 1));
          }
        }
      }

      if (_server == null && !_isCancelled) {
        throw "Could not bind server. Please check your network or Hotspot.\n\nTip: Try turning your Hotspot off and on again to reset the connection. (${lastError is SocketException ? lastError.message : lastError})";
      }

      if (_isCancelled) return;
      onUpdate(TransferModel(status: "Ready & Waiting as $deviceName"));

      await for (Socket client in _server!) {
        // If we already have an active transfer, reject the new one immediately
        if (_activeClient != null || _activeSink != null) {
          try {
            client.write(
              "${jsonEncode({"status": "REJECTED", "reason": "BUSY"})}\n",
            );
            await client.flush();
            client.destroy();
          } catch (_) {}
          continue;
        }

        _activeClient = client;
        _isActiveTransferCancelled = false;
        _activeTransferCancelReason = null;
        try {
          _activeClient!.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        Map<String, dynamic>? metadata;
        int totalExpectedBytes = 0;
        int received = 0;
        String? originalName;

        try {
          Stopwatch stopwatch = Stopwatch()..start();
          bool isRejected = false;
          final List<Future<void>> closeFutures = [];

          List<int> headerBuffer = [];

          int currentFileIndex = 0;
          int bytesReadForCurrentFile = 0;
          IOSink? currentSink;
          BytesBuilder? currentBuffer;

          int bytesSinceUpdate = 0;
          DateTime lastTime = DateTime.now();

          chunkLoop:
          await for (var chunk in client.timeout(
            const Duration(seconds: AppConstants.transferTimeoutSeconds),
          )) {
            int offset = 0;

            // Parse JSON header
            if (metadata == null) {
              int newlineIndex = chunk.indexOf(10); // \n
              if (newlineIndex != -1) {
                headerBuffer.addAll(chunk.sublist(0, newlineIndex));

                if (headerBuffer.length > 32 * 1024 * 1024) {
                  // Header is abnormally large — reject gracefully instead of crashing.
                  try {
                    client.write(
                      "${jsonEncode({"status": "REJECTED", "reason": "HEADER_TOO_LARGE"})}\n",
                    );
                    await client.flush();
                    client.destroy();
                  } catch (_) {}
                  isRejected = true;
                  onUpdate(TransferModel(status: "Ready & Waiting..."));
                  break;
                }

                String jsonStr = utf8.decode(headerBuffer);
                metadata = jsonDecode(jsonStr);
                lastReceivedMetadata = metadata;
                originalName = metadata?["fileName"];
                _currentSenderDeviceName =
                    metadata?["senderDeviceName"] ?? "the other device";

                offset = newlineIndex + 1;

                // Authorization step
                List<dynamic> files = metadata!["files"];
                totalExpectedBytes = files.fold(
                  0,
                  (sum, f) => sum + (f["size"] as int),
                );
                double totalSizeMB = totalExpectedBytes / 1024 / 1024;

                // Pre-fetch storage space concurrently in the background while the user is viewing the authorization dialog!
                // This ensures we never block the dialog display and never delay the ready signal after the user accepts.
                final Future<StorageSpace?> freeSpaceFuture =
                    getStorageSpace(lowOnSpaceThreshold: 0, fractionDigits: 1)
                        .timeout(const Duration(milliseconds: 1500))
                        .then<StorageSpace?>((val) => val)
                        .catchError((_) => null);

                bool isAccepted = await onRequestAuth(
                  client.remoteAddress.address,
                  _currentSenderDeviceName ?? "Unknown Device",
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
                  // Update UI immediately to let the user know we accepted and are starting!
                  onUpdate(
                    TransferModel(
                      status: "Connecting & Starting...",
                      totalSize: totalExpectedBytes / 1024 / 1024,
                      progress: 0.0,
                    ),
                  );

                  // Post-acceptance Free Space Check (Awaiting the pre-fetched future, which is already resolved in 0ms)
                  try {
                    StorageSpace? freeSpace = await freeSpaceFuture;
                    if (freeSpace != null &&
                        freeSpace.free < totalExpectedBytes) {
                      client.write(
                        "${jsonEncode({"status": "REJECTED", "reason": "OUT_OF_SPACE"})}\n",
                      );
                      await client.flush();
                      client.destroy();
                      isRejected = true;
                      onUpdate(
                        TransferModel(
                          status:
                              "Transfer rejected: Not enough space "
                              "(need ${(totalSizeMB).toStringAsFixed(1)} MB, "
                              "${freeSpace.freeSize} available). Ready & Waiting...",
                        ),
                      );
                      break;
                    }
                  } catch (e) {
                    // If space check fails for some reason (e.g. platform error),
                    // we proceed as a fallback rather than blocking the transfer.
                  }

                  try {
                    String originalName = metadata["fileName"];
                    // CRITICAL: Sanitize for the current OS (e.g., removing ':' on Windows)
                    String sanitizedName = _sanitizeFileName(originalName);

                    String finalFileName = _generateUniquePath(
                      saveDirectory,
                      sanitizedName,
                    );

                    if (finalFileName != originalName) {
                      if (metadata["isFolder"] == true) {
                        for (var fMeta in files) {
                          List<String> segments = p.split(fMeta["path"]);
                          // Sanitize each segment to be safe
                          for (int i = 0; i < segments.length; i++) {
                            segments[i] = _sanitizeFileName(segments[i]);
                          }
                          segments[0] = finalFileName;
                          fMeta["path"] = p
                              .joinAll(segments)
                              .replaceAll(r'\', '/');
                        }
                      } else {
                        if (files.isNotEmpty) {
                          files[0]["path"] = finalFileName;
                        }
                      }
                    }

                    client.write("${jsonEncode({"s": "r"})}\n");
                    await client.flush();
                  } catch (_) {
                    throw "Sender disconnected before starting.";
                  }
                }
              } else {
                headerBuffer.addAll(chunk);
                if (headerBuffer.length > 32 * 1024 * 1024) {
                  // Header is abnormally large — reject gracefully instead of crashing.
                  try {
                    client.write(
                      "${jsonEncode({"status": "REJECTED", "reason": "HEADER_TOO_LARGE"})}\n",
                    );
                    await client.flush();
                    client.destroy();
                  } catch (_) {}
                  isRejected = true;
                  onUpdate(TransferModel(status: "Ready & Waiting..."));
                  break;
                }
                continue;
              }
            }

            List<dynamic> files = metadata["files"];
            try {
              while (offset < chunk.length && currentFileIndex < files.length) {
                var fileMeta = files[currentFileIndex];
                int targetSize = fileMeta["size"];

                // Open file for writing if not already open
                if (currentSink == null && currentBuffer == null) {
                  bytesReadForCurrentFile = 0;
                  String savePath = p.join(saveDirectory, fileMeta["path"]);
                  final parentPath = p.dirname(savePath);
                  if (!createdDirs.contains(parentPath)) {
                    try {
                      Directory(parentPath).createSync(recursive: true);
                      createdDirs.add(parentPath);
                    } catch (_) {}
                  }

                  if (targetSize <= 512 * 1024) {
                    currentBuffer = BytesBuilder(copy: false);
                  } else {
                    File f = File(savePath);
                    currentSink = f.openWrite();
                    _activeSink = currentSink;
                  }
                }

                int remainingInChunk = chunk.length - offset;
                int bytesNeeded = targetSize - bytesReadForCurrentFile;
                int bytesToProcess = remainingInChunk <= bytesNeeded
                    ? remainingInChunk
                    : bytesNeeded;

                if (bytesToProcess > 0) {
                  if (currentBuffer != null) {
                    currentBuffer.add(
                      Uint8List.sublistView(
                        chunk,
                        offset,
                        offset + bytesToProcess,
                      ),
                    );
                  } else if (currentSink != null) {
                    currentSink.add(
                      Uint8List.sublistView(
                        chunk,
                        offset,
                        offset + bytesToProcess,
                      ),
                    );
                  }
                  bytesReadForCurrentFile += bytesToProcess;
                  received += bytesToProcess;
                  bytesSinceUpdate += bytesToProcess;
                  offset += bytesToProcess;
                } else if (targetSize == 0) {
                  bytesReadForCurrentFile = 0;
                }

                // Update speed in UI
                final now = DateTime.now();
                final elapsedMs = now.difference(lastTime).inMilliseconds;
                if (elapsedMs > AppConstants.speedUpdateIntervalMs) {
                  double speed =
                      (bytesSinceUpdate / 1024 / 1024) / (elapsedMs / 1000.0);
                  onUpdate(
                    TransferModel(
                      speed: speed,
                      transferred: received / 1024 / 1024,
                      fileName: p.basename(fileMeta["path"]),
                      status: "Receiving Data...",
                      totalSize: totalExpectedBytes / 1024 / 1024,
                      progress: totalExpectedBytes > 0
                          ? received / totalExpectedBytes
                          : 0.0,
                    ),
                  );
                  bytesSinceUpdate = 0;
                  lastTime = now;
                }

                // Close/flush file when fully received
                if (bytesReadForCurrentFile == targetSize) {
                  if (currentBuffer != null) {
                    final bufferToSave = currentBuffer;
                    currentBuffer = null;
                    final fileSavePath = p.join(
                      saveDirectory,
                      fileMeta["path"],
                    );

                    final writeFuture = () async {
                      try {
                        final f = File(fileSavePath);
                        await f.writeAsBytes(
                          bufferToSave.takeBytes(),
                          flush: false,
                        );
                      } catch (_) {}
                    }();
                    closeFutures.add(writeFuture);
                  } else if (currentSink != null) {
                    var sinkToClose = currentSink;
                    currentSink = null;
                    _activeSink = null;
                    closeFutures.add(sinkToClose.close().catchError((_) {}));
                  }

                  bytesReadForCurrentFile = 0;
                  currentFileIndex++;

                  if (received >= totalExpectedBytes) {
                    break chunkLoop; // Exit the chunk loop early since we have everything
                  }
                }
              }
            } finally {
              if (currentSink != null && currentFileIndex >= files.length) {
                closeFutures.add(currentSink.close().catchError((_) {}));
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

          // Final cleanup for any streams or buffers left open
          if (currentBuffer != null) {
            final bufferToSave = currentBuffer;
            currentBuffer = null;
            if (metadata != null && metadata["files"] != null) {
              final List<dynamic> filesList = metadata["files"];
              if (currentFileIndex < filesList.length) {
                var fileMeta = filesList[currentFileIndex];
                final fileSavePath = p.join(saveDirectory, fileMeta["path"]);
                final writeFuture = () async {
                  try {
                    final f = File(fileSavePath);
                    await f.writeAsBytes(
                      bufferToSave.takeBytes(),
                      flush: false,
                    );
                  } catch (_) {}
                }();
                closeFutures.add(writeFuture);
              }
            }
          }

          if (currentSink != null) {
            if (received >= totalExpectedBytes) {
              onUpdate(
                TransferModel(
                  status: "Finalizing... Saving to disk",
                  transferred: received / 1024 / 1024,
                  totalSize: totalExpectedBytes / 1024 / 1024,
                  progress: 1.0,
                  fileName: originalName ?? "",
                ),
              );
            }
            closeFutures.add(currentSink.close().catchError((_) {}));
            currentSink = null;
            _activeSink = null;
          }

          // Wait for all background file closures/writes to complete before finishing
          if (closeFutures.isNotEmpty) {
            await Future.wait(closeFutures);
          }

          // Guard: if metadata is null, the sender connected but dropped
          if (metadata == null) {
            onUpdate(TransferModel(status: "Ready & Waiting as $deviceName"));
            break;
          }

          // Check for premature connection drop
          if (received < totalExpectedBytes) {
            throw "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}";
          }

          // Send tiny done signal since everything is safely written to disk
          if (received >= totalExpectedBytes) {
            try {
              client.write('${jsonEncode({"s": "d"})}\n');
              await client.flush();
            } catch (_) {}
          }

          stopwatch.stop();
          double finalMB = received / 1024 / 1024;

          onUpdate(
            TransferModel(
              status: "Transfer Complete!",
              transferred: finalMB,
              totalSize: finalMB,
              progress: 1.0,
              avgSpeed: (finalMB / (stopwatch.elapsedMilliseconds / 1000))
                  .toStringAsFixed(2),
              totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(
                1,
              ),
              fileName: originalName ?? "Multiple Items",
            ),
          );

          // All done signal and writes completed
        } on PathAccessException {
          onUpdate(TransferModel(status: "Error: Permission Denied"));
        } catch (e) {
          if (_isCancelled) {
            onUpdate(
              TransferModel(
                status: _cancelReason ?? "Transfer Cancelled.",
                transferred: received / 1024 / 1024,
                totalSize: totalExpectedBytes / 1024 / 1024,
                progress: totalExpectedBytes > 0
                    ? received / totalExpectedBytes
                    : 0.0,
                fileName: originalName ?? "",
              ),
            );
          } else if (_isActiveTransferCancelled) {
            onUpdate(
              TransferModel(
                status: _activeTransferCancelReason ?? "Transfer Cancelled.",
                transferred: received / 1024 / 1024,
                totalSize: totalExpectedBytes / 1024 / 1024,
                progress: totalExpectedBytes > 0
                    ? received / totalExpectedBytes
                    : 0.0,
                fileName: originalName ?? "",
              ),
            );
          } else if (e is SocketException) {
            onUpdate(
              TransferModel(
                status: _mapReceiverSocketError(e),
                transferred: received / 1024 / 1024,
                totalSize: totalExpectedBytes / 1024 / 1024,
                progress: totalExpectedBytes > 0
                    ? received / totalExpectedBytes
                    : 0.0,
                fileName: originalName ?? "",
              ),
            );
          } else if (e is TimeoutException) {
            onUpdate(
              TransferModel(
                status:
                    "Transfer cancelled by ${_currentSenderDeviceName ?? 'sender'} (Connection Timeout).",
                transferred: received / 1024 / 1024,
                totalSize: totalExpectedBytes / 1024 / 1024,
                progress: totalExpectedBytes > 0
                    ? received / totalExpectedBytes
                    : 0.0,
                fileName: originalName ?? "",
              ),
            );
          } else {
            String errorMsg = e.toString();
            if (errorMsg.endsWith('.')) {
              errorMsg = errorMsg.substring(0, errorMsg.length - 1);
            }
            onUpdate(
              TransferModel(
                status: "$errorMsg. Ready & Waiting...",
                transferred: received / 1024 / 1024,
                totalSize: totalExpectedBytes / 1024 / 1024,
                progress: totalExpectedBytes > 0
                    ? received / totalExpectedBytes
                    : 0.0,
                fileName: originalName ?? "",
              ),
            );
          }
        } finally {
          try {
            // CRITICAL: Ensure the file sink is closed on connection drop
            if (_activeSink != null) {
              await _activeSink?.close();
            }
            client.destroy();
          } catch (_) {}
          _activeClient = null;
          _activeSink = null;
        }
      }
    } on PathAccessException {
      onUpdate(TransferModel(status: "Error: Permission Denied"));
    } catch (e) {
      if (_isCancelled) {
        onUpdate(TransferModel(status: _cancelReason ?? "Transfer Cancelled"));
      } else if (e is SocketException) {
        final msg = e.message.toLowerCase();
        final osError = e.osError?.errorCode;
        if (osError == 104 ||
            osError == 10054 ||
            osError == 32 ||
            msg.contains("connection reset by peer")) {
          onUpdate(
            TransferModel(
              status:
                  "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}.",
            ),
          );
        } else {
          onUpdate(
            TransferModel(
              status:
                  "Network Error: Please check network or Hotspot connection.",
            ),
          );
        }
      } else if (e is TimeoutException) {
        onUpdate(
          TransferModel(
            status:
                "Transfer cancelled by ${_currentSenderDeviceName ?? 'sender'} (Connection Timeout).",
          ),
        );
      } else {
        onUpdate(TransferModel(status: "Error: $e"));
      }
    } finally {
      _activeClient = null;
      _activeSink = null;
      _isCancelled = false;
      onDone(); // Only call onDone when the method truly finishes (server closed)
    }
  }

  /// Cancels only the active transfer connection without stopping the server.
  void cancelActiveTransfer({String? reason}) {
    _isActiveTransferCancelled = true;
    _activeTransferCancelReason = reason;

    if (_activeClient != null) {
      try {
        _activeClient!.write(
          "${jsonEncode({"status": "REJECTED", "reason": "CANCELLED"})}\n",
        );
        _activeClient!.flush().then((_) {
          _activeClient?.destroy();
          _activeClient = null;
        });
      } catch (_) {}
    }

    // CRITICAL: Close the active file sink to release file locks
    _activeSink?.close();
    _activeSink = null;
  }

  /// Stops the receiver server and cancels any active transfer.
  void stop({String? reason}) {
    _isCancelled = true;
    _cancelReason = reason;

    if (_activeClient != null) {
      try {
        _activeClient!.write("${jsonEncode({"status": "REJECTED"})}\n");
        _activeClient!.flush().then((_) {
          _activeClient?.destroy();
          _activeClient = null;
        });
      } catch (_) {}
    }

    _server?.close();
    _server = null;

    // CRITICAL: Close the active file sink to release file locks
    _activeSink?.close();
    _activeSink = null;
  }

  /// Maps a [SocketException] to a user-friendly error message for receiver.
  String _mapReceiverSocketError(SocketException e) {
    final msg = e.message.toLowerCase();
    final osError = e.osError?.errorCode;
    if (osError == 104 ||
        osError == 10054 ||
        osError == 32 ||
        msg.contains("connection reset by peer")) {
      return "Transfer cancelled by ${_currentSenderDeviceName ?? 'sender'}. Ready & Waiting...";
    } else {
      return "Network lost. Ready & Waiting...";
    }
  }

  /// Sanitizes a filename by removing illegal characters for the current platform.
  String _sanitizeFileName(String name) {
    // Basic sanitization for all platforms (remove path separators)
    String sanitized = name.replaceAll(RegExp(r'[/\\]'), '_');

    if (Platform.isWindows) {
      // Windows illegal characters: < > : " / \ | ? *
      sanitized = sanitized.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      // Reserved names (CON, PRN, etc.)
      final reserved = RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$',
        caseSensitive: false,
      );
      if (reserved.hasMatch(sanitized)) {
        sanitized = "file_$sanitized";
      }
    }

    // Ensure the name isn't empty or just dots
    if (sanitized.isEmpty || sanitized.trim().replaceAll('.', '').isEmpty) {
      sanitized = "received_file_${DateTime.now().millisecondsSinceEpoch}";
    }

    return sanitized;
  }

  /// Generates a unique path by appending (1), (2), etc. if the file or directory exists.
  String _generateUniquePath(String dir, String name) {
    String checkPath = p.join(dir, name);
    if (!File(checkPath).existsSync() && !Directory(checkPath).existsSync()) {
      return name;
    }
    String extension = p.extension(name);
    String base = p.basenameWithoutExtension(name);
    int counter = 1;
    while (true) {
      String newName = '$base ($counter)$extension';
      String newCheckPath = p.join(dir, newName);
      if (!File(newCheckPath).existsSync() &&
          !Directory(newCheckPath).existsSync()) {
        return newName;
      }
      counter++;
    }
  }
}
