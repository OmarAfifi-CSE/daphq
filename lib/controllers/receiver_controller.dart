import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:storage_space/storage_space.dart';
import '../models/transfer_model.dart';

export '../models/transfer_model.dart' show TransferPhase;
import '../core/app_constants.dart';

/// Handles the receiver side of the file transfer protocol.
///
/// Binds a TCP server, accepts incoming connections, parses the JSON metadata
/// header, requests user authorization, then writes incoming bytes to disk.
class ReceiverController {
  static int _fallbackNameCounter = 0;

  ServerSocket? _server;
  Socket? _activeClient;
  IOSink? _activeSink;
  String? _activePartialPath;
  final Set<String> _activePartialPaths = <String>{};
  void Function()? _activeAuthDismissCallback;
  bool _isCancelled = false;
  String? _cancelReason;
  bool _isActiveTransferCancelled = false;
  String? _activeTransferCancelReason;
  String? _currentSenderDeviceName;
  Map<String, dynamic>? lastReceivedMetadata;

  /// Machine-readable lifecycle phase (plan T-002) — set at control-flow
  /// boundaries so the cubit never parses status strings again.
  TransferPhase currentPhase = TransferPhase.idle;

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
    required void Function() onDone,
    void Function()? onAuthDismissed,
    int port = AppConstants.transferPort,
    void Function(int boundPort)? onListening,
    Future<int?> Function()? freeBytesProvider,
  }) async {
    _isCancelled = false;
    _cancelReason = null;
    currentPhase = TransferPhase.idle;
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
            phase: TransferPhase.idle,
          ),
        );
        try {
          // Primary strategy: Bind to all interfaces (0.0.0.0)
          _server = await ServerSocket.bind(
            InternetAddress.anyIPv4,
            port,
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
                      port,
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
      onListening?.call(_server!.port);
      currentPhase = TransferPhase.idle;
      onUpdate(
        TransferModel(
          status: "Ready & Waiting as $deviceName",
          phase: TransferPhase.idle,
        ),
      );

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
        _activeAuthDismissCallback = onAuthDismissed;
        _isActiveTransferCancelled = false;
        _activeTransferCancelReason = null;

        // Wrap the transfer logic in an asynchronous closure so it doesn't block the ServerSocket from accepting/rejecting other connections!
        () async {
          try {
            _activeClient!.setOption(SocketOption.tcpNoDelay, true);
          } catch (_) {}
          Map<String, dynamic>? metadata;
          int totalExpectedBytes = 0;
          int received = 0;
          String? originalName;
          final Stopwatch stopwatch = Stopwatch();

          try {
            bool isRejected = false;
            final List<Future<void>> closeFutures = [];

            List<int> headerBuffer = [];

            int currentFileIndex = 0;
            int bytesReadForCurrentFile = 0;
            IOSink? currentSink;
            BytesBuilder? currentBuffer;
            String? currentSavePath;
            String? currentPartialPath;

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
                    currentPhase = TransferPhase.idle;
                    onUpdate(
                      TransferModel(
                        status: "Ready & Waiting...",
                        phase: TransferPhase.idle,
                      ),
                    );
                    break;
                  }

                  String jsonStr = utf8.decode(headerBuffer);
                  final decoded = jsonDecode(jsonStr);
                  if (decoded is! Map<String, dynamic>) {
                    throw "Invalid transfer metadata.";
                  }
                  metadata = decoded;
                  lastReceivedMetadata = metadata;
                  originalName = metadata["fileName"]?.toString();
                  _currentSenderDeviceName =
                      metadata["senderDeviceName"]?.toString() ??
                      "the other device";

                  offset = newlineIndex + 1;

                  // Validate files list and total expected payload up-front
                  final rawFiles = metadata["files"];
                  if (rawFiles is! List || rawFiles.isEmpty) {
                    throw "No valid files in transfer metadata.";
                  }
                  totalExpectedBytes = 0;
                  for (final entry in rawFiles) {
                    if (entry is! Map ||
                        entry["path"] is! String ||
                        entry["size"] is! int ||
                        (entry["size"] as int) < 0) {
                      throw "Invalid file entry in transfer metadata.";
                    }
                    totalExpectedBytes += entry["size"] as int;
                  }
                  double totalSizeMB = totalExpectedBytes / 1024 / 1024;

                  // Pre-fetch storage space concurrently in the background while the user is viewing the authorization dialog!
                  // This ensures we never block the dialog display and never delay the ready signal after the user accepts.
                  final Future<int?> freeSpaceBytesFuture =
                      freeBytesProvider != null
                      ? freeBytesProvider().catchError((_) => null)
                      : getStorageSpace(
                              lowOnSpaceThreshold: 0,
                              fractionDigits: 1,
                            )
                            .timeout(const Duration(milliseconds: 1500))
                            .then<int?>((val) => val.free)
                            .catchError((_) => null);

                  currentPhase = TransferPhase.waitingAuth;
                  final bool isAccepted = await onRequestAuth(
                    client.remoteAddress.address,
                    _currentSenderDeviceName ?? "Unknown Device",
                    rawFiles.length,
                    totalSizeMB,
                  ).timeout(
                    const Duration(minutes: AppConstants.authTimeoutMinutes),
                    onTimeout: () {
                      onAuthDismissed?.call();
                      return false;
                    },
                  );

                  if (!isAccepted || _isCancelled || _isActiveTransferCancelled) {
                    try {
                      client.write("${jsonEncode({"status": "REJECTED"})}\n");
                      await client.flush();
                    } catch (_) {}
                    client.destroy();
                    isRejected = true;
                    currentPhase = TransferPhase.idle;
                    onUpdate(
                      TransferModel(
                        status: "Transfer Rejected. Ready & Waiting...",
                        phase: TransferPhase.idle,
                      ),
                    );
                    break;
                  } else {
                    // Update UI immediately to let the user know we accepted and are starting!
                    currentPhase = TransferPhase.receiving;
                    onUpdate(
                      TransferModel(
                        status: "Connecting & Starting...",
                        totalSize: totalExpectedBytes / 1024 / 1024,
                        progress: 0.0,
                        fileName: originalName ?? "",
                        phase: TransferPhase.receiving,
                      ),
                    );

                    // Post-acceptance Free Space Check (Awaiting the pre-fetched future, which is already resolved in 0ms)
                    try {
                      final int? freeBytes = await freeSpaceBytesFuture;
                      if (freeBytes != null && freeBytes < totalExpectedBytes) {
                        client.write(
                          "${jsonEncode({"status": "REJECTED", "reason": "OUT_OF_SPACE"})}\n",
                        );
                        await client.flush();
                        client.destroy();
                        isRejected = true;
                        currentPhase = TransferPhase.idle;
                        final freeMb = (freeBytes / 1024 / 1024).toStringAsFixed(1);
                        onUpdate(
                          TransferModel(
                            status:
                                "Transfer rejected: Not enough space "
                                "(need ${(totalSizeMB).toStringAsFixed(1)} MB, "
                                "$freeMb MB available). Ready & Waiting...",
                            phase: TransferPhase.idle,
                          ),
                        );
                        break;
                      }
                    } catch (_) {
                      // If space check fails for some reason (e.g. platform error),
                      // we proceed as a fallback rather than blocking the transfer.
                    }

                    // Resolve collision-safe & traversal-safe target paths for every item
                    try {
                      _prepareTargetPaths(saveDirectory, metadata);
                    } catch (e) {
                      try {
                        client.write(
                          "${jsonEncode({"status": "REJECTED", "reason": "INVALID_PATH"})}\n",
                        );
                        await client.flush();
                        client.destroy();
                      } catch (_) {}
                      rethrow;
                    }

                    try {
                      client.write("${jsonEncode({"s": "r"})}\n");
                      await client.flush();
                      stopwatch.start();
                    } catch (_) {
                      throw "Sender disconnected before starting.";
                    }

                    final List<dynamic> initialFiles =
                        metadata["files"] as List<dynamic>;
                    currentFileIndex = await _drainZeroByteFiles(
                      files: initialFiles,
                      currentFileIndex: currentFileIndex,
                      saveDirectory: saveDirectory,
                      createdDirs: createdDirs,
                      closeFutures: closeFutures,
                    );
                    if (currentFileIndex >= initialFiles.length) {
                      break chunkLoop;
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
                    currentPhase = TransferPhase.idle;
                    onUpdate(
                      TransferModel(
                        status: "Ready & Waiting...",
                        phase: TransferPhase.idle,
                      ),
                    );
                    break;
                  }
                  continue;
                }
              }

              final List<dynamic> files = metadata["files"] as List<dynamic>;
              while (offset < chunk.length && currentFileIndex < files.length) {
                final fileMeta = files[currentFileIndex];
                final int targetSize = fileMeta["size"] as int;

                // Open target partial for writing if not already open
                if (currentSink == null && currentBuffer == null) {
                  bytesReadForCurrentFile = 0;
                  final savePath = _resolveContainmentCheckedPath(
                    saveDirectory,
                    fileMeta["path"] as String,
                  );
                  final parentPath = p.dirname(savePath);
                  if (!createdDirs.contains(parentPath)) {
                    Directory(parentPath).createSync(recursive: true);
                    createdDirs.add(parentPath);
                  }

                  currentSavePath = savePath;
                  currentPartialPath = '$savePath.daphq-partial';

                  if (targetSize <= 512 * 1024) {
                    currentBuffer = BytesBuilder(copy: false);
                  } else {
                    _activePartialPath = currentPartialPath;
                    _activePartialPaths.add(currentPartialPath);
                    final f = File(currentPartialPath);
                    currentSink = f.openWrite();
                    _activeSink = currentSink;
                  }
                }

                final int remainingInChunk = chunk.length - offset;
                final int bytesNeeded = targetSize - bytesReadForCurrentFile;
                final int bytesToProcess = remainingInChunk <= bytesNeeded
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
                }

                // Update speed in UI
                final now = DateTime.now();
                final elapsedMs = now.difference(lastTime).inMilliseconds;
                if (elapsedMs > AppConstants.speedUpdateIntervalMs) {
                  final double speed =
                      (bytesSinceUpdate / 1024 / 1024) / (elapsedMs / 1000.0);
                  onUpdate(
                    TransferModel(
                      speed: speed,
                      transferred: received / 1024 / 1024,
                      fileName: p.basename(fileMeta["path"] as String),
                      status: "Receiving Data...",
                      totalSize: totalExpectedBytes / 1024 / 1024,
                      progress: totalExpectedBytes > 0
                          ? received / totalExpectedBytes
                          : 0.0,
                      phase: TransferPhase.receiving,
                    ),
                  );
                  bytesSinceUpdate = 0;
                  lastTime = now;
                }

                // Finalize current file when its full payload is received
                if (bytesReadForCurrentFile == targetSize) {
                  final String targetPath = currentSavePath!;
                  final String partialPath = currentPartialPath!;
                  currentSavePath = null;
                  currentPartialPath = null;

                  if (currentBuffer != null) {
                    final bufferToSave = currentBuffer;
                    currentBuffer = null;
                    _activePartialPaths.add(partialPath);
                    closeFutures.add(
                      _finalizeBufferedFile(
                        partialPath: partialPath,
                        targetPath: targetPath,
                        bytes: bufferToSave.takeBytes(),
                      ),
                    );
                  } else if (currentSink != null) {
                    final sinkToClose = currentSink;
                    currentSink = null;
                    if (identical(_activeSink, sinkToClose)) {
                      _activeSink = null;
                    }
                    closeFutures.add(
                      _finalizeStreamedFile(
                        sink: sinkToClose,
                        partialPath: partialPath,
                        targetPath: targetPath,
                      ),
                    );
                  }

                  // Bound concurrent disk finalizations to protect FDs and RAM
                  if (closeFutures.length >= 64) {
                    await Future.wait(closeFutures);
                    closeFutures.clear();
                  }

                  bytesReadForCurrentFile = 0;
                  currentFileIndex++;

                  // Drain any zero-byte files immediately so trailing empty
                  // files are finalized without waiting for extra socket chunks.
                  currentFileIndex = await _drainZeroByteFiles(
                    files: files,
                    currentFileIndex: currentFileIndex,
                    saveDirectory: saveDirectory,
                    createdDirs: createdDirs,
                    closeFutures: closeFutures,
                  );

                  if (currentFileIndex >= files.length) {
                    break chunkLoop;
                  }
                }
              }
            } // end await for chunk

            if (isRejected) {
              return;
            }

            if (_isCancelled || _isActiveTransferCancelled) {
              if (currentSink != null) {
                final sink = currentSink;
                currentSink = null;
                if (identical(_activeSink, sink)) _activeSink = null;
                try {
                  await sink.close();
                } catch (_) {}
              }
              throw _activeTransferCancelReason ??
                  _cancelReason ??
                  "Transfer Cancelled";
            }

            // Guard: if metadata is null, the sender connected but dropped before header
            if (metadata == null) {
              currentPhase = TransferPhase.idle;
              onUpdate(
                TransferModel(
                  status: "Ready & Waiting as $deviceName",
                  phase: TransferPhase.idle,
                ),
              );
              return;
            }

            // Check for premature connection drop before finalizing partials
            if (received < totalExpectedBytes) {
              if (currentSink != null) {
                final sink = currentSink;
                currentSink = null;
                if (identical(_activeSink, sink)) _activeSink = null;
                try {
                  await sink.close();
                } catch (_) {}
              }
              currentBuffer = null;
              throw "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}";
            }

            final List<dynamic> files = metadata["files"] as List<dynamic>;

            // Handle an open file if the stream ended right at its byte boundary (e.g. 0-byte file)
            if (currentFileIndex < files.length &&
                (currentBuffer != null || currentSink != null)) {
              final int targetSize = files[currentFileIndex]["size"] as int;
              if (bytesReadForCurrentFile == targetSize &&
                  currentSavePath != null &&
                  currentPartialPath != null) {
                final String targetPath = currentSavePath;
                final String partialPath = currentPartialPath;
                currentSavePath = null;
                currentPartialPath = null;

                if (currentBuffer != null) {
                  final bufferToSave = currentBuffer;
                  currentBuffer = null;
                  _activePartialPaths.add(partialPath);
                  closeFutures.add(
                    _finalizeBufferedFile(
                      partialPath: partialPath,
                      targetPath: targetPath,
                      bytes: bufferToSave.takeBytes(),
                    ),
                  );
                } else if (currentSink != null) {
                  final sinkToClose = currentSink;
                  currentSink = null;
                  if (identical(_activeSink, sinkToClose)) {
                    _activeSink = null;
                  }
                  closeFutures.add(
                    _finalizeStreamedFile(
                      sink: sinkToClose,
                      partialPath: partialPath,
                      targetPath: targetPath,
                    ),
                  );
                }
                currentFileIndex++;
              }
            }

            // Create any trailing 0-byte files remaining in metadata after all payload bytes arrived
            currentFileIndex = await _drainZeroByteFiles(
              files: files,
              currentFileIndex: currentFileIndex,
              saveDirectory: saveDirectory,
              createdDirs: createdDirs,
              closeFutures: closeFutures,
            );
            if (currentFileIndex < files.length) {
              throw "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}";
            }

            // Notify finalizing phase while draining all background disk writes & atomic renames
            if (closeFutures.isNotEmpty) {
              currentPhase = TransferPhase.finalizing;
              onUpdate(
                TransferModel(
                  status: "Finalizing... Saving to disk",
                  transferred: received / 1024 / 1024,
                  totalSize: totalExpectedBytes / 1024 / 1024,
                  progress: 1.0,
                  fileName: originalName ?? "",
                  phase: TransferPhase.finalizing,
                ),
              );
              await Future.wait(closeFutures);
              closeFutures.clear();
            }

            // Send tiny done signal since everything is safely written & renamed on disk
            try {
              client.write('${jsonEncode({"s": "d"})}\n');
              await client.flush();
            } catch (_) {}

            stopwatch.stop();
            final double finalMB = received / 1024 / 1024;
            final double elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
            final double avgSpeed =
                elapsedSec > 0.001 ? (finalMB / elapsedSec) : 0.0;
            currentPhase = TransferPhase.done;

            onUpdate(
              TransferModel(
                status: "Transfer Complete!",
                transferred: finalMB,
                totalSize: finalMB,
                progress: 1.0,
                avgSpeed: avgSpeed.toStringAsFixed(2),
                totalTime: elapsedSec.toStringAsFixed(1),
                fileName: originalName ?? "Multiple Items",
                phase: TransferPhase.done,
              ),
            );

            // All done signal and writes completed
          } on PathAccessException {
            currentPhase = TransferPhase.failed;
            onUpdate(
              TransferModel(
                status: "Error: Permission Denied",
                totalSize: totalExpectedBytes / 1024 / 1024,
                fileName: originalName ?? "",
                phase: TransferPhase.failed,
              ),
            );
          } catch (e) {
            if (_isCancelled ||
                _isActiveTransferCancelled ||
                e is TimeoutException) {
              currentPhase = TransferPhase.cancelled;
            } else if (e is SocketException) {
              final osError = e.osError?.errorCode;
              final msg = e.message.toLowerCase();
              currentPhase = (osError == 104 ||
                      osError == 10054 ||
                      osError == 32 ||
                      msg.contains('connection reset by peer'))
                  ? TransferPhase.cancelled
                  : TransferPhase.failed;
            } else if (e.toString().contains('Transfer cancelled')) {
              currentPhase = TransferPhase.cancelled;
            } else {
              currentPhase = TransferPhase.failed;
            }
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
                  phase: TransferPhase.cancelled,
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
                  phase: TransferPhase.cancelled,
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
                  phase: currentPhase,
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
                  phase: TransferPhase.cancelled,
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
                  phase: currentPhase,
                ),
              );
            }
          } finally {
            try {
              onAuthDismissed?.call();
              // CRITICAL: Close active sink BEFORE deleting partials so OS releases file handle
              if (_activeSink != null) {
                try {
                  await _activeSink!.close();
                } catch (_) {}
                _activeSink = null;
              }
              // Plan T-010: remove any incomplete .daphq-partial files on abort/error
              for (final partial in _activePartialPaths.toList()) {
                _safeDeleteFile(partial);
              }
              _activePartialPaths.clear();
              if (_activePartialPath != null) {
                _safeDeleteFile(_activePartialPath!);
                _activePartialPath = null;
              }
              client.destroy();
            } catch (_) {}
            _activeAuthDismissCallback = null;
            _activeClient = null;
            _activeSink = null;
          }
        }();
      }
    } on PathAccessException {
      currentPhase = TransferPhase.failed;
      onUpdate(
        TransferModel(
          status: "Error: Permission Denied",
          phase: TransferPhase.failed,
        ),
      );
    } catch (e) {
      if (_isCancelled || e is TimeoutException) {
        currentPhase = TransferPhase.cancelled;
      } else if (e is SocketException) {
        final osError = e.osError?.errorCode;
        final msg = e.message.toLowerCase();
        currentPhase = (osError == 104 ||
                osError == 10054 ||
                osError == 32 ||
                msg.contains('connection reset by peer'))
            ? TransferPhase.cancelled
            : TransferPhase.failed;
      } else {
        currentPhase = TransferPhase.failed;
      }
      if (_isCancelled) {
        onUpdate(
          TransferModel(
            status: _cancelReason ?? "Transfer Cancelled",
            phase: TransferPhase.cancelled,
          ),
        );
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
              phase: TransferPhase.cancelled,
            ),
          );
        } else {
          onUpdate(
            TransferModel(
              status:
                  "Network Error: Please check network or Hotspot connection.",
              phase: TransferPhase.failed,
            ),
          );
        }
      } else if (e is TimeoutException) {
        onUpdate(
          TransferModel(
            status:
                "Transfer cancelled by ${_currentSenderDeviceName ?? 'sender'} (Connection Timeout).",
            phase: TransferPhase.cancelled,
          ),
        );
      } else {
        onUpdate(
          TransferModel(
            status: "Error: $e",
            phase: currentPhase,
          ),
        );
      }
    } finally {
      _activeAuthDismissCallback?.call();
      _activeAuthDismissCallback = null;
      _activeClient = null;
      _activeSink = null;
      _isCancelled = false;
      onDone(); // Only call onDone when the method truly finishes (server closed)
    }
  }

  /// Finalizes any consecutive zero-byte entries starting at [currentFileIndex]
  /// and returns the next unconsumed file index.
  Future<int> _drainZeroByteFiles({
    required List<dynamic> files,
    required int currentFileIndex,
    required String saveDirectory,
    required Set<String> createdDirs,
    required List<Future<void>> closeFutures,
  }) async {
    while (currentFileIndex < files.length &&
        (files[currentFileIndex]["size"] as int) == 0) {
      final zeroMeta = files[currentFileIndex];
      final zeroPath = _resolveContainmentCheckedPath(
        saveDirectory,
        zeroMeta["path"] as String,
      );
      final parentPath = p.dirname(zeroPath);
      if (!createdDirs.contains(parentPath)) {
        Directory(parentPath).createSync(recursive: true);
        createdDirs.add(parentPath);
      }
      final partialPath = '$zeroPath.daphq-partial';
      _activePartialPaths.add(partialPath);
      closeFutures.add(
        _finalizeBufferedFile(
          partialPath: partialPath,
          targetPath: zeroPath,
          bytes: Uint8List(0),
        ),
      );
      if (closeFutures.length >= 64) {
        await Future.wait(closeFutures);
        closeFutures.clear();
      }
      currentFileIndex++;
    }
    return currentFileIndex;
  }

  /// Writes [bytes] into [partialPath] and atomically renames to [targetPath].
  /// On any error, deletes [partialPath] and rethrows so the transfer fails cleanly.
  Future<void> _finalizeBufferedFile({
    required String partialPath,
    required String targetPath,
    required Uint8List bytes,
  }) async {
    final pf = File(partialPath);
    try {
      await pf.writeAsBytes(bytes, flush: false);
      pf.renameSync(targetPath);
    } catch (_) {
      _safeDeleteFile(partialPath);
      rethrow;
    } finally {
      _activePartialPaths.remove(partialPath);
    }
  }

  /// Drains [sink] into [partialPath] and atomically renames to [targetPath].
  Future<void> _finalizeStreamedFile({
    required IOSink sink,
    required String partialPath,
    required String targetPath,
  }) async {
    final pf = File(partialPath);
    try {
      await sink.close();
      pf.renameSync(targetPath);
    } catch (_) {
      _safeDeleteFile(partialPath);
      rethrow;
    } finally {
      if (identical(_activePartialPath, partialPath)) {
        _activePartialPath = null;
      }
      _activePartialPaths.remove(partialPath);
    }
  }

  static void _safeDeleteFile(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Resolves [rawRelPath] inside [saveDirectory], enforcing T-001 traversal
  /// rejection and strict path containment.
  static String _resolveContainmentCheckedPath(
    String saveDirectory,
    String rawRelPath,
  ) {
    final safeRel = safeRelativePath(rawRelPath);
    if (safeRel == null) {
      throw "Security: rejected an unsafe path in the transfer metadata.";
    }
    final String savePath = p.join(saveDirectory, safeRel);
    final String resolvedSavePath = p.normalize(savePath);
    if (!p.isWithin(p.normalize(saveDirectory), resolvedSavePath)) {
      throw "Security: rejected a path escaping the receive folder.";
    }
    return savePath;
  }

  /// Validates every metadata file path against traversal and remaps each
  /// top-level item to a collision-free name under [saveDirectory], preserving
  /// existing files/folders on disk and preventing intra-batch overwrites.
  static void _prepareTargetPaths(
    String saveDirectory,
    Map<String, dynamic> metadata,
  ) {
    final List<dynamic> files = metadata["files"] as List<dynamic>;
    if (files.isEmpty) return;

    final String? originalName = metadata["fileName"]?.toString();
    final bool isFolder = metadata["isFolder"] == true;

    if (!isFolder && files.length == 1) {
      final safeRel = safeRelativePath(files[0]["path"] as String);
      if (safeRel == null) {
        throw "Security: rejected an unsafe path in the transfer metadata.";
      }
      final String sanitizedRoot = originalName != null &&
              originalName.isNotEmpty
          ? _sanitizeFileName(originalName)
          : p.posix.split(safeRel).first;
      files[0]["path"] = _generateUniquePath(saveDirectory, sanitizedRoot);
      return;
    }

    // Validate all relative paths up-front and collect unique top-level roots.
    final Map<String, String> rootRemap = {};
    final Set<String> reservedLower = {};
    final List<List<String>> parsedSegments = [];

    for (final fMeta in files) {
      final safeRel = safeRelativePath(fMeta["path"] as String);
      if (safeRel == null) {
        throw "Security: rejected an unsafe path in the transfer metadata.";
      }
      final segments = p.posix.split(safeRel);
      parsedSegments.add(segments);

      final String rawRoot = segments.first;
      if (!rootRemap.containsKey(rawRoot)) {
        final String uniqueRoot = _generateUniquePath(
          saveDirectory,
          rawRoot,
          reservedLower: reservedLower,
        );
        rootRemap[rawRoot] = uniqueRoot;
        reservedLower.add(uniqueRoot.toLowerCase());
      }
    }

    // Re-root each file and ensure no two items collide inside the same batch
    // (even from an external/un-deduplicated sender).
    final Set<String> seenTargetsLower = {};
    for (int i = 0; i < files.length; i++) {
      final segments = parsedSegments[i];
      segments[0] = rootRemap[segments.first]!;
      String candidateRel = segments.join('/');

      if (!seenTargetsLower.add(candidateRel.toLowerCase())) {
        final parentIdx = candidateRel.lastIndexOf('/');
        final parent = parentIdx >= 0 ? candidateRel.substring(0, parentIdx + 1) : '';
        final base = p.posix.basenameWithoutExtension(candidateRel);
        final ext = p.posix.extension(candidateRel);
        int counter = 1;
        String uniqueRel;
        do {
          uniqueRel = '$parent$base ($counter)$ext';
          counter++;
        } while (!seenTargetsLower.add(uniqueRel.toLowerCase()));
        candidateRel = uniqueRel;
      }

      files[i]["path"] = candidateRel;
    }
  }

  /// Cancels only the active transfer connection without stopping the server.
  void cancelActiveTransfer({String? reason}) {
    _isActiveTransferCancelled = true;
    _activeTransferCancelReason = reason;
    _activeAuthDismissCallback?.call();

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

    // Close active sink so partial file locks are released before cleanup
    _activeSink?.close();
    _activeSink = null;
  }

  /// Stops the receiver server and cancels any active transfer.
  void stop({String? reason}) {
    _isCancelled = true;
    _cancelReason = reason;
    _activeAuthDismissCallback?.call();

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

  /// Normalizes a relative path from transfer metadata and rejects any
  /// attempt to escape the receive directory (plan T-001).
  ///
  /// - Rejects null bytes, POSIX root paths, and Windows drive-letter/UNC paths
  ///   consistently on every OS.
  /// - Collapses and normalizes separators via POSIX rules, then rejects any
  ///   remaining `..` / `.` segments (traversal).
  /// - Every surviving segment is run through [_sanitizeFileName] so reserved
  ///   names and illegal characters are cleaned before disk writes.
  /// Returns the safe relative path, or null when the path must be rejected.
  static String? safeRelativePath(String raw) {
    if (raw.isEmpty || raw.contains('\x00')) return null;
    final unified = raw.replaceAll(r'\', '/');
    if (unified.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(unified)) {
      return null;
    }
    final normalized = p.posix.normalize(unified);
    if (p.posix.isAbsolute(normalized) ||
        normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      return null;
    }
    final safeSegments = <String>[];
    for (final segment in p.posix.split(normalized)) {
      if (segment.isEmpty || segment == '..' || segment == '.') return null;
      final cleaned = _sanitizeFileName(segment);
      if (cleaned.isEmpty) return null;
      safeSegments.add(cleaned);
    }
    if (safeSegments.isEmpty) return null;
    return safeSegments.join('/');
  }

  /// Sanitizes a filename by removing illegal characters and reserved OS names.
  static String _sanitizeFileName(String name) {
    // Strip path separators and Windows/FAT illegal characters (< > : " / \ | ? *)
    // uniformly so transfers stay valid across Windows and Android storage.
    String sanitized = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

    final reserved = RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$',
      caseSensitive: false,
    );
    if (reserved.hasMatch(sanitized)) {
      sanitized = "file_$sanitized";
    }

    // Ensure the name isn't empty or just dots
    if (sanitized.isEmpty || sanitized.trim().replaceAll('.', '').isEmpty) {
      sanitized = "received_file_${++_fallbackNameCounter}";
    }

    return sanitized;
  }

  /// Generates a unique path by appending (1), (2), etc. if the file or directory exists
  /// on disk or collides (case-insensitively) with [reservedLower].
  static String _generateUniquePath(
    String dir,
    String name, {
    Set<String>? reservedLower,
  }) {
    bool isTaken(String candidate) {
      if (reservedLower != null &&
          reservedLower.contains(candidate.toLowerCase())) {
        return true;
      }
      final String checkPath = p.join(dir, candidate);
      return File(checkPath).existsSync() || Directory(checkPath).existsSync();
    }

    if (!isTaken(name)) return name;

    final String extension = p.posix.extension(name);
    final String base = p.posix.basenameWithoutExtension(name);
    int counter = 1;
    while (true) {
      final String newName = '$base ($counter)$extension';
      if (!isTaken(newName)) return newName;
      counter++;
    }
  }
}
