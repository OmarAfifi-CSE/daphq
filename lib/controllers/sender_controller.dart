import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/app_constants.dart';
import '../models/transfer_model.dart';
import '../security/device_identity_service.dart';
import 'v2_protocol_framing.dart';

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
/// Supports both v1 raw TCP streaming and v2 TLS-pinned adaptive Multi-Stream
/// (`1–4` parallel streams) + Reverse-Connect (for Windows Defender zero-prompt P2P).
class SenderController {
  Socket? _activeSocket;
  final Set<Socket> _activeWorkerSockets = <Socket>{};
  ServerSocket? _reversePlainServer;
  SecureServerSocket? _reverseSecureServer;
  ServerSocket? _reverseFastDataServer;
  Completer<({Socket socket, BufferedSocketReader reader})?>?
      _reverseControlCompleter;
  final Map<int, Completer<Socket>> _reverseDataWaiters =
      <int, Completer<Socket>>{};
  final List<Socket> _reverseUnclaimedData = <Socket>[];
  bool _isCancelled = false;
  int _activeTransferSeq = 0;
  String? _cancelReason;
  bool _wasRejectedByReceiver = false;
  String? _currentTargetDeviceName;

  /// Sends files or folders to the receiver at [targetIp] (or awaits reverse outbound
  /// connections from the receiver when [listenForReverseReceiver] is true).
  Future<void> sendData({
    required List<String> paths,
    required String targetIp,
    required String targetDeviceName,
    required String senderDeviceName,
    required Function(TransferModel) onUpdate,
    int port = AppConstants.transferPort,
    bool useTls = false,
    String? expectedPeerFingerprint,
    String? Function()? expectedPeerFingerprintProvider,
    DeviceIdentity? localIdentity,
    int parallelStreams = 1,
    bool listenForReverseReceiver = false,
    String? reverseAuthToken,
    Duration reverseConnectTimeout = const Duration(seconds: 30),
    void Function(int boundPort)? onReverseListening,
    int? Function()? directFrequencyProvider,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
  }) async {
    final int myTransferSeq = ++_activeTransferSeq;
    _isCancelled = false;
    _cancelReason = null;
    _wasRejectedByReceiver = false;
    _currentTargetDeviceName = targetDeviceName;

    Socket? controlSocket;
    BufferedSocketReader? controlReader;
    final List<BufferedSocketReader> auxiliaryReaders = <BufferedSocketReader>[];
    StreamSubscription<Socket>? reverseAcceptSub;
    StreamSubscription<Socket>? reverseFastAcceptSub;
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
      final List<Map<String, dynamic>> fileList = [];
      int discoveredCount = 0;

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
              return null;
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

      for (final String path in paths) {
        if (_isCancelled) break;
        if (await FileSystemEntity.isDirectory(path)) {
          final dir = Directory(path);
          final fromPath = dir.parent.path;
          const int batchSize = 64;
          final List<File> batch = [];

          await for (final entity
              in dir
                  .list(recursive: true, followLinks: false)
                  .handleError((_) {})) {
            if (_isCancelled) break;
            if (entity is File) {
              batch.add(entity);
              discoveredCount++;

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

      deduplicateRelativePaths(fileList);

      if (fileList.isEmpty) throw "No files found in selection.";

      if (totalSizeBytes == 0) {
        throw "Error: The selected item is empty (0.0 MB).";
      }

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

      final int requestedStreams = parallelStreams.clamp(1, 4);
      final bool isV2Requested = useTls ||
          requestedStreams > 1 ||
          localIdentity != null ||
          listenForReverseReceiver;
      final String sessionId = generateTransferSessionId();

      final String? initialExpectedFp =
          (expectedPeerFingerprint != null &&
                  expectedPeerFingerprint.trim().isNotEmpty)
              ? expectedPeerFingerprint.trim().toLowerCase()
              : null;

      final Map<String, dynamic> metadata = {
        if (isV2Requested) "v": 2,
        if (isV2Requested) "sessionId": sessionId,
        if (isV2Requested) "streams": requestedStreams,
        if (localIdentity != null) "senderPeerId": localIdentity.peerId,
        if (localIdentity != null) "senderFp": localIdentity.certFingerprint,
        "fileName": originalName,
        "fileSize": totalSizeBytes,
        "senderDeviceName": senderDeviceName,
        "isFolder":
            paths.length > 1 || FileSystemEntity.isDirectorySync(paths[0]),
        "files": fileList
            .map((e) => {"path": e["path"], "size": e["size"]})
            .toList(),
      };

      final String preflightHeader = "${jsonEncode(metadata)}\n";

      if (preflightHeader.length > 32 * 1024 * 1024) {
        throw "Too many files selected (${fileList.length} files). "
            "The transfer metadata is too large. "
            "Please select a subfolder instead of the entire drive root.";
      }

      onUpdate(
        TransferModel(
          status: listenForReverseReceiver
              ? "Waiting for direct reverse link..."
              : "Connecting...",
          fileName: originalName,
          phase: TransferPhase.waitingAuth,
        ),
      );

      final Completer<({Socket socket, BufferedSocketReader reader})?>
          reverseControlCompleter =
          Completer<({Socket socket, BufferedSocketReader reader})?>();
      reverseControlCompleter.future.catchError((_) => null);
      _reverseControlCompleter = reverseControlCompleter;
      _reverseDataWaiters.clear();
      _reverseUnclaimedData.clear();

      String? observedPeerFp = initialExpectedFp;

      if (listenForReverseReceiver) {
        final tlsContext = useTls ? localIdentity?.createServerContext() : null;
        final bound = await bindTransferServer(
          port: port,
          retryDelay: const Duration(milliseconds: 250),
          maxAttempts: 4,
          isCancelled: () => _isCancelled,
          onAttempt: (_, _) {},
          tlsContext: tlsContext,
        );
        _reversePlainServer = bound.plain;
        _reverseSecureServer = bound.secure;
        final int boundPort =
            _reverseSecureServer?.port ?? _reversePlainServer?.port ?? port;
        final Stream<Socket> acceptStream =
            _reverseSecureServer ?? _reversePlainServer!;

        reverseAcceptSub = acceptStream.listen(
          (incoming) {
            incoming.setOption(SocketOption.tcpNoDelay, true);
            _dispatchReverseIncomingSocket(
              incoming: incoming,
              expectedSessionId: sessionId,
              expectedReverseToken: reverseAuthToken,
              onControlConnected: (sock, reader) {
                if (!reverseControlCompleter.isCompleted &&
                    !_isCancelled &&
                    myTransferSeq == _activeTransferSeq) {
                  reverseControlCompleter.complete(
                    (socket: sock, reader: reader),
                  );
                } else {
                  unawaited(reader.cancel());
                  sock.destroy();
                }
              },
              onDataWorkerConnected: (workerIdx, sock, reader) {
                if (_isCancelled || myTransferSeq != _activeTransferSeq) {
                  unawaited(reader.cancel());
                  sock.destroy();
                  return;
                }
                auxiliaryReaders.add(reader);
                final waiter = _reverseDataWaiters.remove(workerIdx);
                if (waiter != null && !waiter.isCompleted) {
                  waiter.complete(sock);
                } else {
                  _reverseUnclaimedData.add(sock);
                }
              },
            );
          },
          onError: (_) {},
          cancelOnError: false,
        );

        onReverseListening?.call(boundPort);
        final ctrl = await reverseControlCompleter.future.timeout(
          reverseConnectTimeout,
        );
        if (ctrl == null) {
          throw "Transfer Cancelled";
        }
        controlSocket = ctrl.socket;
        controlReader = ctrl.reader;

        if (isV2Requested && parallelStreams > 1) {
          try {
            final fastSrv = await ServerSocket.bind(
              InternetAddress.anyIPv4,
              0,
              shared: true,
            );
            _reverseFastDataServer = fastSrv;
            reverseFastAcceptSub = fastSrv.listen(
              (Socket incoming) {
                if (myTransferSeq != _activeTransferSeq || _isCancelled) {
                  incoming.destroy();
                  return;
                }
                _dispatchReverseIncomingSocket(
                  incoming: incoming,
                  expectedSessionId: sessionId,
                  expectedReverseToken: reverseAuthToken,
                  onControlConnected: (sock, rdr) {
                    unawaited(rdr.cancel());
                    sock.destroy();
                  },
                  onDataWorkerConnected: (workerIdx, sock, rdr) {
                    if (myTransferSeq != _activeTransferSeq || _isCancelled) {
                      unawaited(rdr.cancel());
                      sock.destroy();
                      return;
                    }
                    auxiliaryReaders.add(rdr);
                    final waiter = _reverseDataWaiters.remove(workerIdx);
                    if (waiter != null && !waiter.isCompleted) {
                      waiter.complete(sock);
                    } else {
                      _reverseUnclaimedData.add(sock);
                    }
                  },
                );
              },
              onError: (_) {},
              cancelOnError: false,
            );
            metadata["dataPort"] = fastSrv.port;
          } catch (_) {}
        }
      } else {
        controlSocket = await connectTransferSocket(
          host: targetIp,
          port: port,
          useTls: useTls,
          timeout: const Duration(
            seconds: AppConstants.connectionTimeoutSeconds,
          ),
          expectedPeerFingerprint: initialExpectedFp,
          onVerifyPeerFingerprint: useTls
              ? (actualFp) async {
                  observedPeerFp = actualFp.trim().toLowerCase();
                  if (onVerifyPeerFingerprint != null) {
                    return onVerifyPeerFingerprint(actualFp);
                  }
                  return true;
                }
              : onVerifyPeerFingerprint,
        );
        controlReader = BufferedSocketReader(controlSocket);
      }

      if (_isCancelled) throw "Transfer Cancelled";
      _activeSocket = controlSocket;

      if (useTls && !listenForReverseReceiver) {
        final peerCert = controlSocket is SecureSocket
            ? controlSocket.peerCertificate
            : null;
        if (peerCert != null) {
          observedPeerFp =
              DeviceIdentityService.fingerprintFromCertificate(peerCert);
        }
        if (observedPeerFp == null || observedPeerFp!.isEmpty) {
          throw const HandshakeException('Missing receiver TLS certificate');
        }
      }

      if (localIdentity != null && isV2Requested) {
        final String serverFpForProof = listenForReverseReceiver
            ? (useTls ? localIdentity.certFingerprint : 'plain')
            : (useTls ? observedPeerFp! : 'plain');
        final String proofMessage = DeviceIdentityService.buildAuthProofMessage(
          sessionId: sessionId,
          senderPeerId: localIdentity.peerId,
          senderFingerprint: localIdentity.certFingerprint,
          serverFingerprint: serverFpForProof,
        );
        metadata["senderCertPem"] = localIdentity.certificatePem;
        metadata["senderProof"] = DeviceIdentityService.signAuthProof(
          privateKeyPem: localIdentity.privateKeyPem,
          message: proofMessage,
        );
      }

      final int? senderFreqMhz = directFrequencyProvider?.call();
      if (senderFreqMhz != null && senderFreqMhz > 0) {
        metadata["freqMhz"] = senderFreqMhz;
      }

      final String header = "${jsonEncode(metadata)}\n";
      if (header.length > 32 * 1024 * 1024) {
        throw "Too many files selected (${fileList.length} files). "
            "The transfer metadata is too large. "
            "Please select a subfolder instead of the entire drive root.";
      }

      try {
        controlSocket.write(header);
        await controlSocket.flush();
      } on SocketException {
        throw "Connection lost before sending data. Please check network/Hotspot.";
      }

      final Completer<Map<String, dynamic>> readyCompleter = Completer();
      final Completer<void> doneCompleter = Completer();
      readyCompleter.future.catchError((_) => <String, dynamic>{});
      doneCompleter.future.catchError((_) {});

      unawaited(
        controlReader.drainLines(
          onLine: (line) {
            try {
              final Map<String, dynamic> response =
                  jsonDecode(line) as Map<String, dynamic>;
              if (response["status"] == "REJECTED") {
                final reason = response["reason"];
                final String targetLabel =
                    _currentTargetDeviceName ?? 'Receiver';
                final String errorMsg = reason == "OUT_OF_SPACE"
                    ? "Transfer rejected by $targetLabel: Insufficient storage space."
                    : reason == "HEADER_TOO_LARGE"
                    ? "Too many files — the transfer metadata is too large. Please select a subfolder instead."
                    : reason == "CANCELLED"
                    ? "Transfer cancelled by $targetLabel."
                    : reason == "BUSY"
                    ? "$targetLabel is busy with another transfer."
                    : "Transfer rejected by $targetLabel.";
                _isCancelled = true;
                _wasRejectedByReceiver = true;
                _cancelReason = errorMsg;
                if (!readyCompleter.isCompleted) {
                  readyCompleter.completeError(errorMsg);
                }
                if (!doneCompleter.isCompleted) {
                  doneCompleter.completeError(errorMsg);
                }
                _abortInflightTransport(
                  errorMsg,
                  controlSocket: controlSocket,
                );
              } else if (response["s"] == "r") {
                if (!readyCompleter.isCompleted) {
                  readyCompleter.complete(response);
                }
              } else if (response["s"] == "d") {
                if (!doneCompleter.isCompleted) {
                  doneCompleter.complete();
                }
              }
            } catch (_) {}
          },
          onError: (_) => _handleControlChannelDisconnect(
            readyCompleter: readyCompleter,
            doneCompleter: doneCompleter,
            controlSocket: controlSocket,
          ),
          onDone: () => _handleControlChannelDisconnect(
            readyCompleter: readyCompleter,
            doneCompleter: doneCompleter,
            controlSocket: controlSocket,
          ),
        ),
      );

      onUpdate(
        TransferModel(
          status: "Waiting for ${_currentTargetDeviceName ?? 'Receiver'} to accept...",
          fileName: originalName,
          totalSize: totalSizeBytes / 1024 / 1024,
          phase: TransferPhase.waitingAuth,
        ),
      );

      late final Map<String, dynamic> readyResponse;
      try {
        readyResponse = await readyCompleter.future.timeout(
          const Duration(minutes: AppConstants.authTimeoutMinutes),
          onTimeout: () => throw "Timeout",
        );
      } catch (e) {
        if (e == "Timeout") {
          throw "Receiver disconnected or timeout before answering.";
        }
        rethrow;
      }

      final int negotiatedVersion = (readyResponse["v"] as num?)?.toInt() ?? 1;
      final int acceptedStreams =
          ((readyResponse["streams"] as num?)?.toInt() ?? 1).clamp(1, 4);
      final int? readyDataPort = (readyResponse["dataPort"] as num?)?.toInt();
      final int? readyFreqMhz = (readyResponse["freqMhz"] as num?)?.toInt();
      if (readyFreqMhz != null && readyFreqMhz > 0) {
        onPeerReportedFrequency?.call(readyFreqMhz);
      }

      if (useTls && negotiatedVersion >= 2) {
        final String? readyReceiverFp =
            (readyResponse["receiverFp"] as String?)?.trim().toLowerCase();
        final String? dynamicExpectedFp =
            expectedPeerFingerprintProvider?.call()?.trim().toLowerCase();
        final String? effectiveExpectedFp =
            (dynamicExpectedFp != null && dynamicExpectedFp.isNotEmpty)
                ? dynamicExpectedFp
                : observedPeerFp;

        if (!listenForReverseReceiver) {
          if (readyReceiverFp != null &&
              readyReceiverFp.isNotEmpty &&
              effectiveExpectedFp != null &&
              readyReceiverFp != effectiveExpectedFp) {
            throw const HandshakeException(
              'Receiver READY identity does not match TLS certificate',
            );
          }
        } else {
          if (readyReceiverFp == null || readyReceiverFp.length != 64) {
            throw const HandshakeException(
              'Missing receiver certificate fingerprint in reverse READY',
            );
          }
          if (effectiveExpectedFp != null &&
              effectiveExpectedFp.isNotEmpty &&
              readyReceiverFp != effectiveExpectedFp) {
            throw const HandshakeException(
              'Reverse receiver certificate fingerprint mismatch',
            );
          }
          final String? readyPeerId =
              (readyResponse["receiverPeerId"] as String?)?.trim().toLowerCase();
          final String? readyCertPem =
              readyResponse["receiverCertPem"] as String?;
          final String? readyProof = readyResponse["receiverProof"] as String?;
          if (localIdentity != null) {
            if (readyPeerId == null ||
                readyPeerId.isEmpty ||
                readyCertPem == null ||
                readyProof == null ||
                readyProof.isEmpty) {
              throw const HandshakeException(
                'Missing reverse receiver ECDSA identity proof',
              );
            }
            final String msg = DeviceIdentityService.buildAuthProofMessage(
              sessionId: sessionId,
              senderPeerId: readyPeerId,
              senderFingerprint: readyReceiverFp,
              serverFingerprint: localIdentity.certFingerprint,
            );
            final bool proofOk = DeviceIdentityService.verifyAuthProof(
              senderCertPem: readyCertPem,
              expectedFingerprint: readyReceiverFp,
              message: msg,
              signatureB64: readyProof,
            );
            if (!proofOk) {
              throw const HandshakeException(
                'Reverse receiver ECDSA identity proof invalid',
              );
            }
          }
          observedPeerFp = readyReceiverFp;
          if (onVerifyPeerFingerprint != null) {
            final allowed = await onVerifyPeerFingerprint(readyReceiverFp);
            if (!allowed) {
              throw const HandshakeException(
                'Reverse receiver TLS certificate rejected by trust policy',
              );
            }
          }
        }
      }

      stopwatch.start();
      onUpdate(
        TransferModel(
          status: "Sending files...",
          fileName: originalName,
          totalSize: totalSizeBytes / 1024 / 1024,
          progress: 0.0,
          phase: TransferPhase.sending,
        ),
      );

      final speedTracker = TransferSpeedTracker();

      void reportBytesSent(int deltaBytes, String activeFileName) {
        sentBytes += deltaBytes;
        speedTracker.recordBytes(deltaBytes, activeFileName, (speed, fileName) {
          onUpdate(
            TransferModel(
              speed: speed,
              transferred: sentBytes / 1024 / 1024,
              fileName: fileName,
              status: "Sending files...",
              totalSize: totalSizeBytes / 1024 / 1024,
              progress: totalSizeBytes > 0 ? sentBytes / totalSizeBytes : 0.0,
              phase: TransferPhase.sending,
            ),
          );
        });
      }

      if (negotiatedVersion >= 2 && acceptedStreams > 1) {
        final int workerChunkSize = totalSizeBytes >= 32 * 1024 * 1024
            ? 2 * 1024 * 1024
            : 1024 * 1024;
        final stealer = ChunkWorkStealer(fileList, chunkSize: workerChunkSize);

        Future<Socket> acquireWorkerSocket(int workerIdx) async {
          if (listenForReverseReceiver) {
            if (_reverseUnclaimedData.isNotEmpty) {
              return _reverseUnclaimedData.removeAt(0);
            }
            final c = Completer<Socket>();
            _reverseDataWaiters[workerIdx] = c;
            return c.future.timeout(
              const Duration(seconds: 15),
            );
          }

          final bool useFastDataPort =
              readyDataPort != null && readyDataPort > 0;
          final sock = await connectTransferSocket(
            host: targetIp,
            port: useFastDataPort ? readyDataPort : port,
            useTls: useFastDataPort ? false : useTls,
            timeout: const Duration(
              seconds: AppConstants.connectionTimeoutSeconds,
            ),
            expectedPeerFingerprint: useFastDataPort ? null : observedPeerFp,
          );
          sock.write(
            '${jsonEncode({"v": 2, "role": "data", "sessionId": sessionId, "workerIndex": workerIdx})}\n',
          );
          await sock.flush();
          return sock;
        }

        bool sessionAborted = false;
        Object? firstWorkerError;
        bool isWorkerAborted() =>
            _isCancelled ||
            sessionAborted ||
            myTransferSeq != _activeTransferSeq;

        void abortWorkersImmediately(Object error) {
          sessionAborted = true;
          firstWorkerError ??= error;
          for (final waiter in _reverseDataWaiters.values) {
            if (!waiter.isCompleted) {
              waiter.completeError(error);
            }
          }
          _reverseDataWaiters.clear();
          for (final ws in _activeWorkerSockets.toList()) {
            try {
              ws.destroy();
            } catch (_) {}
          }
        }

        await Future.wait(
          List<Future<void>>.generate(acceptedStreams, (workerIdx) async {
            if (isWorkerAborted()) return;
            Socket? workerSocket;
            RandomAccessFile? cachedRaf;
            try {
              workerSocket = await acquireWorkerSocket(workerIdx);
              if (isWorkerAborted()) {
                workerSocket.destroy();
                return;
              }
              _activeWorkerSockets.add(workerSocket);
              int? cachedFileIdx;
              int? cachedRafCursor;
              int buffered = 0;
              String lastFileName = '';
              Future<void>? pendingFlush;
              Object? flushError;

              Future<void> awaitPendingFlush() async {
                final inflight = pendingFlush;
                if (inflight == null) return;
                pendingFlush = null;
                await inflight;
                if (flushError != null) {
                  throw flushError!;
                }
              }

              while (!isWorkerAborted()) {
                final task = stealer.nextTask();
                if (task == null) break;

                if (cachedFileIdx != task.fileIndex) {
                  await cachedRaf?.close();
                  cachedRaf = await File(task.absPath).open(
                    mode: FileMode.read,
                  );
                  cachedFileIdx = task.fileIndex;
                  cachedRafCursor = 0;
                }

                // Read header+payload into one contiguous frame buffer while
                // any prior pipelined socket flush drains over TLS/TCP.
                final frameLen = daphqFrameHeaderSize + task.length;
                final frameBuf = Uint8List(frameLen);
                if (cachedRafCursor != task.offset) {
                  await cachedRaf!.setPosition(task.offset);
                }
                int totalRead = 0;
                while (totalRead < task.length) {
                  final readCount = await cachedRaf!.readInto(
                    frameBuf,
                    daphqFrameHeaderSize + totalRead,
                    frameLen,
                  );
                  if (readCount <= 0) break;
                  totalRead += readCount;
                }
                if (totalRead != task.length) {
                  throw "File '${p.basename(task.absPath)}' changed on disk during transfer.";
                }
                cachedRafCursor = task.offset + totalRead;
                if (isWorkerAborted()) break;

                await awaitPendingFlush();
                if (isWorkerAborted()) break;

                lastFileName = p.basename(task.absPath);
                writeV2FrameHeaderTo(
                  frameBuf,
                  fileIndex: task.fileIndex,
                  fileOffset: task.offset,
                  payloadLength: task.length,
                );
                workerSocket.add(frameBuf);
                reportBytesSent(task.length, lastFileName);
                buffered += frameLen;

                if (buffered >= AppConstants.socketFlushThresholdBytes) {
                  buffered = 0;
                  pendingFlush = workerSocket.flush().catchError((Object err) {
                    flushError ??= err;
                  });
                }
              }

              await awaitPendingFlush();
              if (buffered > 0 && !isWorkerAborted()) {
                await workerSocket.flush();
              }

              if (isWorkerAborted()) {
                throw firstWorkerError ?? "Transfer Cancelled";
              }

              workerSocket.add(buildV2EofFrame());
              await workerSocket.flush();
            } catch (e) {
              abortWorkersImmediately(e);
            } finally {
              await cachedRaf?.close();
              if (workerSocket != null) {
                _activeWorkerSockets.remove(workerSocket);
                if (isWorkerAborted()) {
                  workerSocket.destroy();
                } else {
                  try {
                    await workerSocket.close().timeout(
                      const Duration(seconds: 2),
                    );
                  } catch (_) {
                    workerSocket.destroy();
                  }
                }
              }
            }
          }),
        );
        if (firstWorkerError != null) {
          throw firstWorkerError!;
        }
      } else {
        // Legacy v1 single-socket raw payload pump
        int bytesBuffered = 0;
        for (final f in fileList) {
          if (_isCancelled) throw "Transfer Cancelled";
          final File fileToRead = File(f["absPath"] as String);
          final int fileSize = f["size"] as int;
          int bytesSentForFile = 0;

          if (fileSize <= 64 * 1024) {
            try {
              final bytes = await fileToRead.readAsBytes();
              if (_isCancelled) throw "Transfer Cancelled";
              if (bytes.length != fileSize) {
                throw "File '${p.basename(f["absPath"] as String)}' changed on disk during transfer.";
              }
              controlSocket.add(bytes);
              bytesSentForFile = bytes.length;
              bytesBuffered += bytes.length;

              if (bytesBuffered >= AppConstants.socketFlushThresholdBytes) {
                await controlSocket.flush();
                bytesBuffered = 0;
              }
              reportBytesSent(bytes.length, p.basename(f["path"] as String));
            } catch (e) {
              if (_isCancelled) throw "Transfer Cancelled";
              if (e is SocketException ||
                  e.toString().contains("reset by peer")) {
                throw "Receiver disconnected during transfer.";
              }
              rethrow;
            }
          } else {
            final reader = fileToRead.openRead();
            await for (final chunk in reader) {
              if (_isCancelled) throw "Transfer Cancelled";
              bytesSentForFile += chunk.length;
              if (bytesSentForFile > fileSize) {
                throw "File '${p.basename(f["absPath"] as String)}' grew on disk during transfer.";
              }
              try {
                controlSocket.add(chunk);
                bytesBuffered += chunk.length;
                if (bytesBuffered >= AppConstants.socketFlushThresholdBytes) {
                  await controlSocket.flush();
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
              reportBytesSent(chunk.length, p.basename(f["path"] as String));
            }
            if (bytesSentForFile != fileSize) {
              throw "File '${p.basename(f["absPath"] as String)}' changed on disk during transfer.";
            }
          }
        }
        await controlSocket.flush();
      }

      stopwatch.stop();
      final double finalMB = totalSizeBytes / 1024 / 1024;
      final double elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
      final double avg = elapsedSec > 0.001 ? (finalMB / elapsedSec) : 0.0;

      onUpdate(
        TransferModel(
          status: "Finishing up...",
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

      await controlReader.cancel();
      await controlSocket.close();

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
    } on HandshakeException catch (e) {
      final msg =
          "Security Alert: Peer identity verification failed (${e.message}).";
      onUpdate(
        TransferModel(
          status: msg,
          fileName: originalName ?? "",
          phase: TransferPhase.failed,
        ),
      );
      throw TransferSendException(msg, TransferPhase.failed);
    } on TlsException catch (e) {
      final msg = "Security Alert: TLS handshake failed (${e.message}).";
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
            "Couldn't reach ${_currentTargetDeviceName ?? 'the other device'}. Make sure both devices are connected to the same Wi-Fi or Hotspot.";
        terminalPhase = TransferPhase.failed;
      } else {
        final raw = e.toString();
        terminalStatus = raw.startsWith('Error: ') ? raw.substring(7) : raw;
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
      if (_reverseControlCompleter != null &&
          !_reverseControlCompleter!.isCompleted) {
        _reverseControlCompleter!.completeError('Transfer Cancelled');
      }
      _reverseControlCompleter = null;
      for (final waiter in _reverseDataWaiters.values) {
        if (!waiter.isCompleted) {
          waiter.completeError('Transfer Cancelled');
        }
      }
      _reverseDataWaiters.clear();
      for (final sock in _reverseUnclaimedData) {
        try {
          sock.destroy();
        } catch (_) {}
      }
      _reverseUnclaimedData.clear();

      try {
        await reverseAcceptSub?.cancel();
      } catch (_) {}
      try {
        await reverseFastAcceptSub?.cancel();
      } catch (_) {}
      try {
        await _reverseSecureServer?.close();
      } catch (_) {}
      try {
        await _reversePlainServer?.close();
      } catch (_) {}
      try {
        await _reverseFastDataServer?.close();
      } catch (_) {}
      _reverseSecureServer = null;
      _reversePlainServer = null;
      _reverseFastDataServer = null;

      try {
        await controlReader?.cancel();
      } catch (_) {}
      for (final r in auxiliaryReaders) {
        try {
          await r.cancel();
        } catch (_) {}
      }
      auxiliaryReaders.clear();
      for (final ws in _activeWorkerSockets.toList()) {
        try {
          ws.destroy();
        } catch (_) {}
      }
      _activeWorkerSockets.clear();
      try {
        controlSocket?.destroy();
      } catch (_) {}
      _activeSocket = null;
      if (myTransferSeq == _activeTransferSeq) {
        _isCancelled = false;
      }
    }
  }

  /// Handles abrupt control socket errors/closures prior to terminal `DONE`
  /// completion so in-flight workers and reverse waiters abort immediately.
  void _handleControlChannelDisconnect({
    required Completer<Map<String, dynamic>> readyCompleter,
    required Completer<void> doneCompleter,
    Socket? controlSocket,
  }) {
    if (readyCompleter.isCompleted && doneCompleter.isCompleted) {
      return;
    }
    if (readyCompleter.isCompleted && !doneCompleter.isCompleted) {
      _isCancelled = true;
      _cancelReason ??=
          "Transfer cancelled by ${_currentTargetDeviceName ?? 'the other device'}";
    }
    _abortInflightTransport(
      "Receiver disconnected.",
      controlSocket: controlSocket,
    );
    if (!readyCompleter.isCompleted) {
      readyCompleter.completeError("Receiver disconnected.");
    }
    if (!doneCompleter.isCompleted) {
      doneCompleter.completeError("Receiver disconnected.");
    }
  }

  /// Tears down any pending reverse-connect waiters, unclaimed sockets,
  /// worker data sockets, and control socket immediately so the sender exits
  /// without waiting for socket timeouts when the receiver rejects or cancels.
  void _abortInflightTransport(Object error, {Socket? controlSocket}) {
    if (_reverseControlCompleter != null &&
        !_reverseControlCompleter!.isCompleted) {
      _reverseControlCompleter!.completeError(error);
    }
    _reverseControlCompleter = null;
    for (final waiter in _reverseDataWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(error);
      }
    }
    _reverseDataWaiters.clear();
    for (final sock in _reverseUnclaimedData.toList()) {
      try {
        sock.destroy();
      } catch (_) {}
    }
    _reverseUnclaimedData.clear();
    for (final ws in _activeWorkerSockets.toList()) {
      try {
        ws.destroy();
      } catch (_) {}
    }
    _activeWorkerSockets.clear();
    try {
      controlSocket?.destroy();
    } catch (_) {}
    try {
      _activeSocket?.destroy();
    } catch (_) {}
    _activeSocket = null;
    unawaited(_reverseSecureServer?.close());
    unawaited(_reversePlainServer?.close());
    unawaited(_reverseFastDataServer?.close());
    _reverseSecureServer = null;
    _reversePlainServer = null;
    _reverseFastDataServer = null;
  }

  void _dispatchReverseIncomingSocket({
    required Socket incoming,
    required String expectedSessionId,
    String? expectedReverseToken,
    required void Function(Socket socket, BufferedSocketReader reader)
        onControlConnected,
    required void Function(
      int workerIndex,
      Socket socket,
      BufferedSocketReader reader,
    )
        onDataWorkerConnected,
  }) async {
    try {
      final reader = BufferedSocketReader(incoming);
      final res = await reader.readJsonHeader(
        maxHeaderBytes: 64 * 1024,
        timeout: const Duration(seconds: 10),
      );
      if (res == null) {
        incoming.destroy();
        return;
      }
      if (expectedReverseToken != null &&
          expectedReverseToken.isNotEmpty &&
          res.header["reverseToken"] != expectedReverseToken) {
        await reader.cancel();
        incoming.destroy();
        return;
      }
      final role = res.header["role"] as String?;
      if (role == "reverse_control") {
        onControlConnected(incoming, reader);
      } else if (role == "data" &&
          res.header["sessionId"] == expectedSessionId) {
        final idx = (res.header["workerIndex"] as num?)?.toInt() ?? 0;
        onDataWorkerConnected(idx, incoming, reader);
      } else {
        await reader.cancel();
        incoming.destroy();
      }
    } catch (_) {
      incoming.destroy();
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

  /// Fails a pending reverse-connect listener setup without marking the
  /// transfer as user-cancelled, so pre-bytes Direct fallback to Router LAN
  /// remains intact.
  void failReverseSetup(Object error, [StackTrace? stackTrace]) {
    if (_reverseControlCompleter != null &&
        !_reverseControlCompleter!.isCompleted) {
      _reverseControlCompleter!.completeError(error, stackTrace);
    }
    for (final waiter in _reverseDataWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(error, stackTrace);
      }
    }
    _reverseDataWaiters.clear();
  }

  /// Cancels an active send operation.
  void cancel({String? reason}) {
    _isCancelled = true;
    _activeTransferSeq++;
    _cancelReason = reason;
    if (_reverseControlCompleter != null &&
        !_reverseControlCompleter!.isCompleted) {
      _reverseControlCompleter!.completeError(reason ?? 'Transfer Cancelled');
    }
    for (final waiter in _reverseDataWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(reason ?? 'Transfer Cancelled');
      }
    }
    _reverseDataWaiters.clear();
    for (final sock in _reverseUnclaimedData) {
      try {
        sock.destroy();
      } catch (_) {}
    }
    _reverseUnclaimedData.clear();
    _reversePlainServer?.close();
    _reverseSecureServer?.close();
    _reverseFastDataServer?.close();
    _activeSocket?.destroy();
    _activeSocket = null;
    for (final ws in _activeWorkerSockets.toList()) {
      try {
        ws.destroy();
      } catch (_) {}
    }
    _activeWorkerSockets.clear();
  }

  /// Maps a [SocketException] to a user-friendly error message.
  String _mapSocketError(SocketException e) {
    final msg = e.message.toLowerCase();
    final osError = e.osError?.errorCode;
    final peerLabel = _currentTargetDeviceName ?? 'the other device';

    if (osError == 111 ||
        osError == 10061 ||
        msg.contains("connection refused")) {
      return "$peerLabel isn't ready to receive yet. Make sure Daphq is open and discoverable on $peerLabel.";
    } else if (osError == 113 ||
        osError == 112 ||
        osError == 10060 ||
        osError == 10065) {
      return "Couldn't reach $peerLabel. Make sure both devices are connected to the same Wi-Fi or Hotspot.";
    } else if (osError == 101 ||
        osError == 10051 ||
        osError == 10053 ||
        osError == 10050 ||
        msg.contains("network is unreachable") ||
        msg.contains("software caused connection abort")) {
      return "Wi-Fi connection was interrupted. Please reconnect and try again.";
    } else if (osError == 104 ||
        osError == 10054 ||
        osError == 32 ||
        msg.contains("connection reset by peer")) {
      return "Transfer cancelled by $peerLabel.";
    } else {
      return "Connection lost with $peerLabel. Please check your Wi-Fi or Hotspot and try again.";
    }
  }
}
