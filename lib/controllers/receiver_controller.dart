import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:storage_space/storage_space.dart';

import '../core/app_constants.dart';
import '../models/transfer_model.dart';
import '../security/device_identity_service.dart';
import 'v2_protocol_framing.dart';

export '../models/transfer_model.dart' show TransferPhase;
export 'v2_protocol_framing.dart' show TransferAuthRequest;

class _V2FileTarget {
  final int index;
  final String partialPath;
  final String targetPath;
  final int targetSize;
  final void Function(String path) onPartialCreated;
  final void Function(String path) onPartialFinalized;
  final void Function(int bytes)? onBytesWritten;
  final bool Function()? shouldFallbackOutOfOrder;
  final void Function(Object error)? onWriteError;

  int bytesReceived = 0;
  final List<({int start, int end})> _writtenRanges = <({int start, int end})>[];
  final V2OrderedChunkCoalescer _coalescer = V2OrderedChunkCoalescer();
  RandomAccessFile? _raf;
  int? _lastWriteCursor;
  bool _isPumping = false;
  bool _hasNewInput = false;
  Completer<void>? _pumpCompleter;
  Object? _writeError;
  bool _dirEnsured = false;
  bool _finalized = false;
  bool _aborted = false;

  _V2FileTarget({
    required this.index,
    required this.partialPath,
    required this.targetPath,
    required this.targetSize,
    required this.onPartialCreated,
    required this.onPartialFinalized,
    this.onBytesWritten,
    this.shouldFallbackOutOfOrder,
    this.onWriteError,
  });

  bool get _isAllBytesRecorded =>
      bytesReceived == targetSize &&
      _writtenRanges.length == 1 &&
      _writtenRanges.first.start == 0 &&
      _writtenRanges.first.end == targetSize;

  void _recordRangeAndMerge(int start, int length) {
    final int end = start + length;
    int insertIdx = 0;
    while (insertIdx < _writtenRanges.length &&
        _writtenRanges[insertIdx].start < start) {
      insertIdx++;
    }
    if (insertIdx > 0 && _writtenRanges[insertIdx - 1].end > start) {
      throw const FormatException('Overlapping or duplicate chunk range');
    }
    if (insertIdx < _writtenRanges.length && _writtenRanges[insertIdx].start < end) {
      throw const FormatException('Overlapping or duplicate chunk range');
    }

    int mergedStart = start;
    int mergedEnd = end;
    if (insertIdx > 0 && _writtenRanges[insertIdx - 1].end == start) {
      mergedStart = _writtenRanges[insertIdx - 1].start;
      _writtenRanges.removeAt(insertIdx - 1);
      insertIdx--;
    }
    if (insertIdx < _writtenRanges.length && _writtenRanges[insertIdx].start == end) {
      mergedEnd = _writtenRanges[insertIdx].end;
      _writtenRanges.removeAt(insertIdx);
    }
    _writtenRanges.insert(insertIdx, (start: mergedStart, end: mergedEnd));
    bytesReceived += length;
  }

  void validateAndRecordChunk(int offset, int length) {
    if (_aborted || _finalized || length == 0) return;
    if (_writeError != null) {
      throw _writeError!;
    }
    if (offset < 0 || offset + length > targetSize) {
      throw const FormatException('Chunk out of file bounds');
    }
    _recordRangeAndMerge(offset, length);
    if (bytesReceived > targetSize) {
      throw const FormatException('Received bytes exceed declared file size');
    }
  }

  void enqueueValidatedChunk(int offset, Uint8List data) {
    if (_aborted || _finalized || data.isEmpty) return;
    if (_writeError != null) {
      throw _writeError!;
    }
    _coalescer.enqueue(offset, data);
    _hasNewInput = true;
    _scheduleWritePump();
  }

  void _scheduleWritePump() {
    if (_isPumping || _aborted || _finalized) return;
    _isPumping = true;
    final completer = Completer<void>();
    _pumpCompleter = completer;
    unawaited(_drainWrites(completer));
  }

  Future<void> _drainWrites(Completer<void> completer) async {
    try {
      while (!_aborted && !_finalized) {
        _hasNewInput = false;
        final bool allArrived = _isAllBytesRecorded;
        final batch = _coalescer.takeNextPartsList(
          allowOutOfOrderFallback:
              allArrived || (shouldFallbackOutOfOrder?.call() ?? false),
        );
        if (batch == null) {
          if (allArrived && _coalescer.isEmpty) {
            if (_raf != null) {
              await _raf!.flush();
              await _raf!.close();
              _raf = null;
              await File(partialPath).rename(targetPath);
              _finalized = true;
              onPartialFinalized(partialPath);
            }
            break;
          }
          break;
        }

        if (!_dirEnsured) {
          await Directory(p.dirname(targetPath)).create(recursive: true);
          _dirEnsured = true;
        }
        if (_raf == null) {
          onPartialCreated(partialPath);
          _raf = await File(partialPath).open(mode: FileMode.write);
          _lastWriteCursor = 0;
        }
        if (_lastWriteCursor != batch.offset) {
          await _raf!.setPosition(batch.offset);
        }
        for (final part in batch.parts) {
          await _raf!.writeFrom(part);
        }
        _lastWriteCursor = batch.offset + batch.totalBytes;
        onBytesWritten?.call(batch.totalBytes);
      }
    } catch (e) {
      _writeError ??= e;
      onWriteError?.call(e);
    } finally {
      _isPumping = false;
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (_hasNewInput &&
          !_aborted &&
          !_finalized &&
          _writeError == null &&
          !_coalescer.isEmpty) {
        _scheduleWritePump();
      }
    }
  }

  Future<void> awaitPendingWrites() async {
    while (true) {
      final pending = _pumpCompleter;
      if (pending != null) {
        await pending.future;
      }
      if (_writeError != null) {
        throw _writeError!;
      }
      if (!_isPumping && _coalescer.isEmpty) {
        break;
      }
      if (!_isPumping && !_coalescer.isEmpty && !_aborted && !_finalized) {
        _scheduleWritePump();
      } else {
        break;
      }
    }
    if (_writeError != null) {
      throw _writeError!;
    }
  }

  Future<void> abortAndCleanup() async {
    _aborted = true;
    final bufferedBytes = _coalescer.pendingBytes;
    _coalescer.clear();
    if (bufferedBytes > 0) {
      onBytesWritten?.call(bufferedBytes);
    }
    try {
      await _pumpCompleter?.future;
    } catch (_) {}
    try {
      await _raf?.close();
    } catch (_) {}
    _raf = null;
    if (!_finalized) {
      try {
        final f = File(partialPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      onPartialFinalized(partialPath);
    }
  }
}

class _V2ReceiveSession {
  static const int maxPendingWriteBytes = 32 * 1024 * 1024;
  static const int outOfOrderFallbackBytes = 2 * 1024 * 1024;

  final String sessionId;
  final int expectedStreams;
  final List<_V2FileTarget> fileTargets;
  final int totalExpectedBytes;
  final Duration chunkTimeout;
  final bool Function() isCancelled;
  final void Function(int bytesDelta, String activeFileName) onProgress;

  final Completer<void> _allWorkersDone = Completer<void>();
  final List<Socket> _workerSockets = <Socket>[];
  final List<Completer<void>> _budgetWaiters = <Completer<void>>[];
  ServerSocket? fastDataServer;
  StreamSubscription<Socket>? fastDataSub;
  int _pendingWriteBytes = 0;
  int _completedWorkers = 0;
  int _connectedWorkers = 0;
  int receivedBytes = 0;
  bool aborted = false;
  bool completedCleanly = false;
  Object? _firstWorkerError;

  bool get shouldFallbackOutOfOrder =>
      _pendingWriteBytes >= outOfOrderFallbackBytes;

  _V2ReceiveSession({
    required this.sessionId,
    required this.expectedStreams,
    required this.fileTargets,
    required this.totalExpectedBytes,
    required this.chunkTimeout,
    required this.isCancelled,
    required this.onProgress,
  }) {
    // Keep _allWorkersDone observed so abort() never leaks an uncaught Zone error
    // if triggered before awaitWorkers() or during catch-block cleanup.
    _allWorkersDone.future.catchError((_) {});
  }

  Future<void> _reserveWriteBudget(int deltaBytes) async {
    while (!aborted &&
        _firstWorkerError == null &&
        _pendingWriteBytes >= maxPendingWriteBytes) {
      final waiter = Completer<void>();
      _budgetWaiters.add(waiter);
      await waiter.future;
    }
    if (aborted || _firstWorkerError != null) return;
    _pendingWriteBytes += deltaBytes;
  }

  void releaseWriteBudget(int deltaBytes) {
    _pendingWriteBytes = (_pendingWriteBytes - deltaBytes).clamp(0, 1 << 30);
    if (_pendingWriteBytes < maxPendingWriteBytes && _budgetWaiters.isNotEmpty) {
      for (final waiter in _budgetWaiters.toList()) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _budgetWaiters.clear();
    }
  }

  void notifyWriteError(Object error) {
    _firstWorkerError ??= error;
    for (final waiter in _budgetWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _budgetWaiters.clear();
    if (!_allWorkersDone.isCompleted) {
      _allWorkersDone.completeError(error);
    }
  }

  Future<void> closeFastDataServer() async {
    final sub = fastDataSub;
    fastDataSub = null;
    final srv = fastDataServer;
    fastDataServer = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await srv?.close();
    } catch (_) {}
  }

  Future<void> runWorkerConnection({
    required Socket socket,
    required BufferedSocketReader reader,
  }) async {
    if (aborted) {
      socket.destroy();
      return;
    }
    _connectedWorkers++;
    _workerSockets.add(socket);

    try {
      await consumeV2WorkerFrames(
        reader: reader,
        chunkTimeout: chunkTimeout,
        isCancelled: () => aborted || isCancelled(),
        onChunk: (int fileIndex, int offset, Uint8List payload) {
          if (fileIndex < 0 || fileIndex >= fileTargets.length) {
            throw const FormatException('Invalid fileIndex in frame');
          }
          final target = fileTargets[fileIndex];
          target.validateAndRecordChunk(offset, payload.length);
          receivedBytes += payload.length;
          if (!aborted &&
              _firstWorkerError == null &&
              _pendingWriteBytes < maxPendingWriteBytes) {
            _pendingWriteBytes += payload.length;
            target.enqueueValidatedChunk(offset, payload);
            onProgress(payload.length, p.basename(target.targetPath));
            return null;
          }
          return () async {
            await _reserveWriteBudget(payload.length);
            if (aborted || _firstWorkerError != null) {
              if (_firstWorkerError != null) throw _firstWorkerError!;
              return;
            }
            target.enqueueValidatedChunk(offset, payload);
            onProgress(payload.length, p.basename(target.targetPath));
          }();
        },
      );
    } catch (e) {
      notifyWriteError(e);
    } finally {
      await reader.cancel();
      try {
        await socket.close();
      } catch (_) {
        socket.destroy();
      }
      _workerSockets.remove(socket);
      _completedWorkers++;
      if (_firstWorkerError == null &&
          _completedWorkers >= expectedStreams &&
          !_allWorkersDone.isCompleted) {
        _allWorkersDone.complete();
      }
    }
  }

  Future<void> awaitWorkers({required Duration idleConnectTimeout}) async {
    // Guard against workers never connecting or partial worker set stalling after READY
    Timer? connectWatchdog;
    if (_connectedWorkers < expectedStreams) {
      connectWatchdog = Timer(idleConnectTimeout, () {
        if (_connectedWorkers < expectedStreams && !_allWorkersDone.isCompleted) {
          _allWorkersDone.completeError(
            TimeoutException(
              'Missing data workers ($_connectedWorkers/$expectedStreams connected)',
            ),
          );
        }
      });
    }
    try {
      await _allWorkersDone.future;
    } finally {
      connectWatchdog?.cancel();
      await closeFastDataServer();
    }
  }

  Future<void> finalizeAndVerify() async {
    for (final target in fileTargets) {
      if (target.targetSize == 0) continue;
      await target.awaitPendingWrites();
      if (!target._finalized) {
        throw 'Transfer incomplete for ${p.basename(target.targetPath)}';
      }
    }
    if (receivedBytes < totalExpectedBytes) {
      throw 'Incomplete multi-stream payload ($receivedBytes / $totalExpectedBytes)';
    }
    completedCleanly = true;
  }

  Future<void> abort() async {
    aborted = true;
    await closeFastDataServer();
    for (final waiter in _budgetWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _budgetWaiters.clear();
    for (final ws in _workerSockets.toList()) {
      try {
        ws.destroy();
      } catch (_) {}
    }
    _workerSockets.clear();
    for (final target in fileTargets) {
      await target.abortAndCleanup();
    }
    if (!_allWorkersDone.isCompleted) {
      _allWorkersDone.completeError('Transfer Cancelled');
    }
  }
}

/// Handles the receiver side of the file transfer protocol.
///
/// Binds a plain TCP or TLS 1.3 server (or connects outbound in Reverse-Connect
/// mode), accepts incoming connections, validates metadata & peer trust/SAS,
/// authorizes, and writes incoming streams atomically via `.daphq-partial`.
class ReceiverController {
  static int _fallbackNameCounter = 0;

  ServerSocket? _plainServer;
  SecureServerSocket? _secureServer;
  Socket? _activeClient;
  Socket? _closingRejectionSocket;
  Future<void> _pendingRejectionFuture = Future<void>.value();

  Future<void> waitForPendingRejection() => _pendingRejectionFuture;
  BufferedSocketReader? _activeClientReader;
  IOSink? _activeSink;
  String? _activePartialPath;
  final Set<String> _activePartialPaths = <String>{};
  _V2ReceiveSession? _activeV2Session;
  bool _hasActiveTransfer = false;
  void Function()? _activeAuthDismissCallback;
  bool _isCancelled = false;
  String? _cancelReason;
  bool _isActiveTransferCancelled = false;
  String? _activeTransferCancelReason;
  String? _currentSenderDeviceName;
  Map<String, dynamic>? lastReceivedMetadata;

  TransferPhase currentPhase = TransferPhase.idle;

  /// Starts listening for incoming transfers over TCP or TLS (`tlsContext != null`).
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
    SecurityContext? tlsContext,
    DeviceIdentity? localIdentity,
    Future<bool> Function(TransferAuthRequest request)? onRequestAuthV2,
    Future<Map<String, dynamic>> Function(DirectControlRequest request)?
        onDirectControlRequest,
    int? Function()? directFrequencyProvider,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    int maxParallelStreams = 4,
  }) async {
    _isCancelled = false;
    _cancelReason = null;
    currentPhase = TransferPhase.idle;
    final Set<String> createdDirs = {};

    try {
      await _closeServers();
      if (_plainServer != null || _secureServer != null) {
        await Future.delayed(const Duration(milliseconds: 200));
      }

      late final ({ServerSocket? plain, SecureServerSocket? secure}) bound;
      try {
        bound = await bindTransferServer(
          port: port,
          fallbackPorts: port == AppConstants.transferPort
              ? AppConstants.transferFallbackPorts
              : const <int>[],
          retryDelay: const Duration(seconds: 1),
          maxAttempts: 5,
          isCancelled: () => _isCancelled,
          tlsContext: tlsContext,
          onAttempt: (attempt, total) {
            onUpdate(
              TransferModel(
                status: "Initializing Server (Attempt $attempt/$total)...",
                phase: TransferPhase.idle,
              ),
            );
          },
        );
      } catch (lastError) {
        if (!_isCancelled) {
          throw "Could not bind server. Please check your network or Hotspot.\n\nTip: Try turning your Hotspot off and on again to reset the connection. (${lastError is SocketException ? lastError.message : lastError})";
        }
        return;
      }

      _plainServer = bound.plain;
      _secureServer = bound.secure;
      final int? boundPort = _secureServer?.port ?? _plainServer?.port;
      if ((_plainServer == null && _secureServer == null) || _isCancelled) {
        return;
      }

      onListening?.call(boundPort!);
      currentPhase = TransferPhase.idle;
      onUpdate(
        TransferModel(
          status: "Ready & Waiting as $deviceName",
          phase: TransferPhase.idle,
        ),
      );

      final Stream<Socket> rawAcceptStream = _secureServer ?? _plainServer!;
      final Stream<Socket> acceptStream = rawAcceptStream.handleError((_) {});
      await for (final Socket client in acceptStream) {
        unawaited(
          _dispatchAcceptedSocket(
            client: client,
            saveDirectory: saveDirectory,
            deviceName: deviceName,
            createdDirs: createdDirs,
            onUpdate: onUpdate,
            onRequestAuth: onRequestAuth,
            onRequestAuthV2: onRequestAuthV2,
            onDirectControlRequest: onDirectControlRequest,
            onAuthDismissed: onAuthDismissed,
            freeBytesProvider: freeBytesProvider,
            localIdentity: localIdentity,
            isTlsConnection: tlsContext != null,
            directFrequencyProvider: directFrequencyProvider,
            onPeerReportedFrequency: onPeerReportedFrequency,
            maxParallelStreams: maxParallelStreams,
          ),
        );
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
      _handleOuterReceiverError(e, onUpdate);
    } finally {
      _activeAuthDismissCallback?.call();
      _activeAuthDismissCallback = null;
      _activeClient = null;
      _activeClientReader = null;
      _activeSink = null;
      _hasActiveTransfer = false;
      _isCancelled = false;
      onDone();
    }
  }

  /// Reverse-Connect mode: Windows receiver dials outbound TCP/TLS to an Android sender
  /// avoiding Windows Defender Public-profile inbound firewall blocks without Admin rights.
  Future<void> acceptReverseTransfer({
    required String senderIp,
    required int port,
    required String saveDirectory,
    required String deviceName,
    required Function(TransferModel) onUpdate,
    Future<bool> Function(
      String senderIp,
      String senderDeviceName,
      int fileCount,
      double totalSizeMB,
    )?
    onRequestAuth,
    Future<bool> Function(TransferAuthRequest request)? onRequestAuthV2,
    void Function()? onAuthDismissed,
    bool useTls = false,
    String? expectedSenderFingerprint,
    String? reverseAuthToken,
    DeviceIdentity? localIdentity,
    Future<int?> Function()? freeBytesProvider,
    int? directFrequencyMhz,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    int maxParallelStreams = 4,
    void Function()? onDone,
  }) async {
    if (_hasActiveTransfer || _activeClient != null || _activeSink != null) {
      return;
    }
    _isCancelled = false;
    _cancelReason = null;
    _isActiveTransferCancelled = false;
    _activeTransferCancelReason = null;
    final Set<String> createdDirs = <String>{};

    Socket? controlSocket;
    BufferedSocketReader? reader;
    bool ownsActiveSlot = false;
    bool bailedBecauseBusy = false;
    try {
      String? pinnedSenderFp = (expectedSenderFingerprint != null &&
              expectedSenderFingerprint.trim().isNotEmpty)
          ? expectedSenderFingerprint.trim().toLowerCase()
          : null;

      controlSocket = await connectTransferSocket(
        host: senderIp,
        port: port,
        useTls: useTls,
        timeout: const Duration(seconds: 15),
        expectedPeerFingerprint: pinnedSenderFp,
        onVerifyPeerFingerprint: (useTls && pinnedSenderFp == null)
            ? (actualFp) async {
                pinnedSenderFp = actualFp.trim().toLowerCase();
                return pinnedSenderFp!.isNotEmpty;
              }
            : null,
      );

      if (_isCancelled || _isActiveTransferCancelled) {
        controlSocket.destroy();
        return;
      }

      if (useTls &&
          pinnedSenderFp == null &&
          controlSocket is SecureSocket &&
          controlSocket.peerCertificate != null) {
        pinnedSenderFp = DeviceIdentityService.fingerprintFromCertificate(
          controlSocket.peerCertificate!,
        );
      }

      controlSocket.write(
        '${jsonEncode({
          "v": 2,
          "role": "reverse_control",
          if (reverseAuthToken != null && reverseAuthToken.isNotEmpty)
            "reverseToken": reverseAuthToken,
          if (localIdentity != null) "receiverPeerId": localIdentity.peerId,
          if (localIdentity != null) "receiverFp": localIdentity.certFingerprint,
        })}\n',
      );
      await controlSocket.flush();

      reader = BufferedSocketReader(controlSocket);
      final headerResult = await reader.readJsonHeader(
        maxHeaderBytes: 32 * 1024 * 1024,
        timeout: const Duration(
          seconds: AppConstants.transferTimeoutSeconds,
        ),
      );
      if (headerResult == null || _isCancelled || _isActiveTransferCancelled) {
        await reader.cancel();
        controlSocket.destroy();
        return;
      }

      if (_hasActiveTransfer || _activeClient != null || _activeSink != null) {
        bailedBecauseBusy = true;
        await reader.cancel();
        await _sendRejectionAndClose(controlSocket, reason: "BUSY");
        return;
      }

      ownsActiveSlot = true;
      _hasActiveTransfer = true;
      _activeClient = controlSocket;
      _activeClientReader = reader;
      _activeAuthDismissCallback = onAuthDismissed;

      await _handleTransferSession(
        client: controlSocket,
        reader: reader,
        metadata: headerResult.header,
        initialPayload: headerResult.initialPayload,
        saveDirectory: saveDirectory,
        deviceName: deviceName,
        createdDirs: createdDirs,
        onUpdate: onUpdate,
        onRequestAuth: onRequestAuth ?? (_, _, _, _) async => false,
        onRequestAuthV2: onRequestAuthV2,
        onAuthDismissed: onAuthDismissed,
        freeBytesProvider: freeBytesProvider,
        localIdentity: localIdentity,
        isTlsConnection: useTls,
        directFrequencyProvider:
            directFrequencyMhz != null ? () => directFrequencyMhz : null,
        onPeerReportedFrequency: onPeerReportedFrequency,
        maxParallelStreams: maxParallelStreams,
        reverseConnectTarget: (
          ip: senderIp,
          port: port,
          useTls: useTls,
          expectedFingerprint: pinnedSenderFp,
          reverseToken: reverseAuthToken,
        ),
      );
    } catch (e) {
      if (!bailedBecauseBusy && (ownsActiveSlot || !_hasActiveTransfer)) {
        _handleOuterReceiverError(e, onUpdate);
      }
    } finally {
      if (ownsActiveSlot) {
        _activeAuthDismissCallback?.call();
        _activeAuthDismissCallback = null;
        _hasActiveTransfer = false;
        _activeClient = null;
        _activeClientReader = null;
        _activeSink = null;
      }
      if (!bailedBecauseBusy) {
        onDone?.call();
      }
    }
  }

  Future<void> _dispatchAcceptedSocket({
    required Socket client,
    required String saveDirectory,
    required String deviceName,
    required Set<String> createdDirs,
    required Function(TransferModel) onUpdate,
    required Future<bool> Function(String, String, int, double) onRequestAuth,
    required Future<bool> Function(TransferAuthRequest)? onRequestAuthV2,
    required Future<Map<String, dynamic>> Function(DirectControlRequest)?
        onDirectControlRequest,
    required void Function()? onAuthDismissed,
    required Future<int?> Function()? freeBytesProvider,
    required DeviceIdentity? localIdentity,
    required bool isTlsConnection,
    int? Function()? directFrequencyProvider,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    required int maxParallelStreams,
  }) async {
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    final reader = BufferedSocketReader(client);
    try {
      final headerResult = await reader.readJsonHeader(
        maxHeaderBytes: 32 * 1024 * 1024,
        timeout: const Duration(
          seconds: AppConstants.transferTimeoutSeconds,
        ),
      );
      if (headerResult == null) {
        client.destroy();
        return;
      }

      final Map<String, dynamic> header = headerResult.header;
      if (header["role"] == "data") {
        final session = _activeV2Session;
        final String? sid = header["sessionId"] as String?;
        if (session == null || sid != session.sessionId || session.aborted) {
          try {
            client.write(
              "${jsonEncode({"status": "REJECTED", "reason": "INVALID_SESSION"})}\n",
            );
            await client.flush();
          } catch (_) {}
          client.destroy();
          return;
        }
        await session.runWorkerConnection(socket: client, reader: reader);
        return;
      }

      if (header["role"] == "direct_control") {
        await _handleDirectControlSocket(
          client: client,
          reader: reader,
          header: header,
          localIdentity: localIdentity,
          isTlsConnection: isTlsConnection,
          onDirectControlRequest: onDirectControlRequest,
        );
        return;
      }

      if (_hasActiveTransfer || _activeClient != null || _activeSink != null) {
        try {
          client.write(
            "${jsonEncode({"status": "REJECTED", "reason": "BUSY"})}\n",
          );
          await client.flush();
          client.destroy();
        } catch (_) {}
        return;
      }

      _hasActiveTransfer = true;
      _activeClient = client;
      _activeClientReader = reader;
      _activeAuthDismissCallback = onAuthDismissed;
      _isActiveTransferCancelled = false;
      _activeTransferCancelReason = null;

      await _handleTransferSession(
        client: client,
        reader: reader,
        metadata: header,
        initialPayload: headerResult.initialPayload,
        saveDirectory: saveDirectory,
        deviceName: deviceName,
        createdDirs: createdDirs,
        onUpdate: onUpdate,
        onRequestAuth: onRequestAuth,
        onRequestAuthV2: onRequestAuthV2,
        onAuthDismissed: onAuthDismissed,
        freeBytesProvider: freeBytesProvider,
        localIdentity: localIdentity,
        isTlsConnection: isTlsConnection,
        directFrequencyProvider: directFrequencyProvider,
        onPeerReportedFrequency: onPeerReportedFrequency,
        maxParallelStreams: maxParallelStreams,
      );
    } on FormatException catch (e) {
      if (e.message == 'HEADER_TOO_LARGE') {
        try {
          client.write(
            "${jsonEncode({"status": "REJECTED", "reason": "HEADER_TOO_LARGE"})}\n",
          );
          await client.flush();
          client.destroy();
        } catch (_) {}
        currentPhase = TransferPhase.idle;
        onUpdate(
          TransferModel(
            status: "Ready & Waiting...",
            phase: TransferPhase.idle,
          ),
        );
      } else {
        client.destroy();
      }
    } catch (_) {
      client.destroy();
    }
  }

  static bool _verifySignedPeerProof({
    required String sessionOrRequestId,
    required String? senderPeerId,
    required String? senderFp,
    required String? senderCertPem,
    required String? senderProof,
    required String? serverFpForProof,
  }) {
    if (sessionOrRequestId.isEmpty ||
        senderPeerId == null ||
        senderPeerId.isEmpty ||
        senderFp == null ||
        senderFp.length != 64 ||
        senderCertPem == null ||
        senderProof == null ||
        serverFpForProof == null ||
        serverFpForProof.isEmpty) {
      return false;
    }
    final String msg = DeviceIdentityService.buildAuthProofMessage(
      sessionId: sessionOrRequestId,
      senderPeerId: senderPeerId,
      senderFingerprint: senderFp,
      serverFingerprint: serverFpForProof,
    );
    return DeviceIdentityService.verifyAuthProof(
      senderCertPem: senderCertPem,
      expectedFingerprint: senderFp,
      message: msg,
      signatureB64: senderProof,
    );
  }

  Future<void> _handleDirectControlSocket({
    required Socket client,
    required BufferedSocketReader reader,
    required Map<String, dynamic> header,
    required DeviceIdentity? localIdentity,
    required bool isTlsConnection,
    required Future<Map<String, dynamic>> Function(DirectControlRequest)?
        onDirectControlRequest,
  }) async {
    Future<void> writeJsonAndClose(Map<String, dynamic> body) async {
      try {
        client.write('${jsonEncode(body)}\n');
        await client.flush();
      } catch (_) {}
      try {
        await reader.cancel();
      } catch (_) {}
      client.destroy();
    }

    final String requestId = (header['requestId'] as String?) ?? '';
    final String action = (header['action'] as String?) ?? '';
    final String? senderPeerId =
        (header['peerId'] as String?)?.trim().toLowerCase();
    final String? senderFp =
        (header['senderFp'] as String?)?.trim().toLowerCase();
    final String? senderCertPem = header['senderCertPem'] as String?;
    final String? senderProof = header['senderProof'] as String?;
    final String senderDeviceName =
        ((header['peerName'] as String?)?.trim().isNotEmpty ?? false)
            ? (header['peerName'] as String).trim()
            : 'Unknown Device';

    final bool verified = isTlsConnection &&
        localIdentity != null &&
        _verifySignedPeerProof(
          sessionOrRequestId: requestId,
          senderPeerId: senderPeerId,
          senderFp: senderFp,
          senderCertPem: senderCertPem,
          senderProof: senderProof,
          serverFpForProof: localIdentity.certFingerprint.trim().toLowerCase(),
        );

    if (!verified || requestId.isEmpty || action.isEmpty) {
      await writeJsonAndClose({'ok': false, 'error': 'unverifiedSender'});
      return;
    }

    if (onDirectControlRequest == null) {
      await writeJsonAndClose({'ok': false, 'error': 'unsupported'});
      return;
    }

    if ((_hasActiveTransfer || _activeClient != null || _activeSink != null) &&
        action != 'teardown') {
      await writeJsonAndClose({'ok': false, 'error': 'busy'});
      return;
    }

    final req = DirectControlRequest(
      requestId: requestId,
      senderIp: client.remoteAddress.address,
      senderPeerId: senderPeerId!,
      senderDeviceName: senderDeviceName,
      senderFingerprint: senderFp,
      action: action,
      ssid: header['ssid'] as String?,
      psk: header['psk'] as String?,
      hostIp: header['hostIp'] as String?,
      port: (header['port'] as num?)?.toInt() ?? 62004,
      useReverseConnect: header['reverseConnect'] == true,
      frequencyMhz: (header['frequencyMhz'] as num?)?.toInt(),
      reverseToken: header['reverseToken'] as String?,
      isIdentityVerified: true,
    );

    try {
      final response = await onDirectControlRequest(req);
      await writeJsonAndClose(response);
    } catch (e) {
      await writeJsonAndClose({'ok': false, 'error': e.toString()});
    }
  }

  Future<void> _handleTransferSession({
    required Socket client,
    required BufferedSocketReader reader,
    required Map<String, dynamic> metadata,
    required Uint8List initialPayload,
    required String saveDirectory,
    required String deviceName,
    required Set<String> createdDirs,
    required Function(TransferModel) onUpdate,
    required Future<bool> Function(String, String, int, double) onRequestAuth,
    required Future<bool> Function(TransferAuthRequest)? onRequestAuthV2,
    required void Function()? onAuthDismissed,
    required Future<int?> Function()? freeBytesProvider,
    required DeviceIdentity? localIdentity,
    required bool isTlsConnection,
    int? Function()? directFrequencyProvider,
    void Function(int frequencyMhz)? onPeerReportedFrequency,
    required int maxParallelStreams,
    ({
      String ip,
      int port,
      bool useTls,
      String? expectedFingerprint,
      String? reverseToken,
    })?
        reverseConnectTarget,
  }) async {
    int totalExpectedBytes = 0;
    int received = 0;
    String? originalName;
    final Stopwatch stopwatch = Stopwatch();
    _V2ReceiveSession? v2Session;

    try {
      bool isRejected = false;
      final List<Future<void>> closeFutures = [];

      lastReceivedMetadata = metadata;
      final int? metaFreqMhz = (metadata["freqMhz"] as num?)?.toInt();
      if (metaFreqMhz != null && metaFreqMhz > 0) {
        onPeerReportedFrequency?.call(metaFreqMhz);
      }
      originalName = metadata["fileName"]?.toString();
      _currentSenderDeviceName =
          metadata["senderDeviceName"]?.toString() ?? "the other device";

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
      final double totalSizeMB = totalExpectedBytes / 1024 / 1024;

      final Future<int?> freeSpaceBytesFuture = freeBytesProvider != null
          ? freeBytesProvider().catchError((_) => null)
          : getStorageSpace(
                  lowOnSpaceThreshold: 0,
                  fractionDigits: 1,
                )
                .timeout(const Duration(milliseconds: 1500))
                .then<int?>((val) => val.free)
                .catchError((_) => null);

      currentPhase = TransferPhase.waitingAuth;
      final String? senderPeerId =
          (metadata["senderPeerId"] as String?)?.trim().toLowerCase();
      final String? senderFp =
          (metadata["senderFp"] as String?)?.trim().toLowerCase();
      final String? senderCertPem = metadata["senderCertPem"] as String?;
      final String? senderProof = metadata["senderProof"] as String?;

      bool isIdentityVerified = false;
      if (isTlsConnection && senderFp != null && senderFp.length == 64) {
        String? reverseTlsFp;
        if (reverseConnectTarget != null &&
            client is SecureSocket &&
            client.peerCertificate != null) {
          reverseTlsFp = DeviceIdentityService.fingerprintFromCertificate(
            client.peerCertificate!,
          );
        }
        final String? serverFpForProof = reverseConnectTarget != null
            ? (reverseTlsFp ??
                reverseConnectTarget.expectedFingerprint?.trim().toLowerCase())
            : localIdentity?.certFingerprint.trim().toLowerCase();

        final bool proofOk = _verifySignedPeerProof(
          sessionOrRequestId: (metadata["sessionId"] as String?) ?? '',
          senderPeerId: senderPeerId,
          senderFp: senderFp,
          senderCertPem: senderCertPem,
          senderProof: senderProof,
          serverFpForProof: serverFpForProof,
        );

        if (reverseConnectTarget != null) {
          final bool matchesReverseTls =
              reverseTlsFp != null && reverseTlsFp == senderFp;
          isIdentityVerified = matchesReverseTls &&
              (senderProof == null || proofOk);
        } else {
          isIdentityVerified = proofOk;
        }
      }

      final bool isAccepted = await (onRequestAuthV2 != null
              ? onRequestAuthV2(
                  TransferAuthRequest(
                    senderIp: client.remoteAddress.address,
                    senderDeviceName:
                        _currentSenderDeviceName ?? "Unknown Device",
                    fileCount: rawFiles.length,
                    totalSizeMB: totalSizeMB,
                    senderPeerId: senderPeerId,
                    senderFingerprint: senderFp,
                    isTls: isTlsConnection,
                    isReverseConnect: reverseConnectTarget != null,
                    isIdentityVerified: isIdentityVerified,
                  ),
                )
              : onRequestAuth(
                  client.remoteAddress.address,
                  _currentSenderDeviceName ?? "Unknown Device",
                  rawFiles.length,
                  totalSizeMB,
                ))
          .timeout(
        const Duration(minutes: AppConstants.authTimeoutMinutes),
        onTimeout: () {
          onAuthDismissed?.call();
          return false;
        },
      );

      if (!isAccepted || _isCancelled || _isActiveTransferCancelled) {
        await _sendRejectionAndClose(client, backgroundLinger: true);
        isRejected = true;
        currentPhase = TransferPhase.idle;
        onUpdate(
          TransferModel(
            status: "Transfer Rejected. Ready & Waiting...",
            phase: TransferPhase.idle,
          ),
        );
        return;
      }

      currentPhase = TransferPhase.receiving;
      onUpdate(
        TransferModel(
          status: "Connecting & Starting...",
          totalSize: totalSizeMB,
          progress: 0.0,
          fileName: originalName ?? "",
          phase: TransferPhase.receiving,
        ),
      );

      try {
        final int? freeBytes = await freeSpaceBytesFuture;
        if (freeBytes != null && freeBytes < totalExpectedBytes) {
          await _sendRejectionAndClose(
            client,
            reason: "OUT_OF_SPACE",
            backgroundLinger: true,
          );
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
          return;
        }
      } catch (_) {}

      try {
        _prepareTargetPaths(saveDirectory, metadata);
      } catch (_) {
        await _sendRejectionAndClose(
          client,
          reason: "INVALID_PATH",
          backgroundLinger: true,
        );
        rethrow;
      }

      final int requestedVersion = (metadata["v"] as num?)?.toInt() ?? 1;
      final int requestedStreams =
          ((metadata["streams"] as num?)?.toInt() ?? 1).clamp(1, 4);
      final String? sessionId = metadata["sessionId"] as String?;
      final int acceptedStreams = (requestedVersion >= 2 &&
              requestedStreams > 1 &&
              sessionId != null &&
              totalExpectedBytes > 0)
          ? requestedStreams.clamp(1, maxParallelStreams)
          : 1;

      final speedTracker = TransferSpeedTracker();

      if (acceptedStreams > 1 && sessionId != null) {
        final List<_V2FileTarget> targets = <_V2FileTarget>[];
        for (var i = 0; i < rawFiles.length; i++) {
          final fileMeta = rawFiles[i];
          final savePath = _resolveContainmentCheckedPath(
            saveDirectory,
            fileMeta["path"] as String,
          );
          targets.add(
            _V2FileTarget(
              index: i,
              partialPath: '$savePath.daphq-partial',
              targetPath: savePath,
              targetSize: fileMeta["size"] as int,
              onPartialCreated: _activePartialPaths.add,
              onPartialFinalized: _activePartialPaths.remove,
              onBytesWritten: (bytes) => v2Session?.releaseWriteBudget(bytes),
              shouldFallbackOutOfOrder: () =>
                  v2Session?.shouldFallbackOutOfOrder ?? false,
              onWriteError: (err) => v2Session?.notifyWriteError(err),
            ),
          );
        }

        v2Session = _V2ReceiveSession(
          sessionId: sessionId,
          expectedStreams: acceptedStreams,
          fileTargets: targets,
          totalExpectedBytes: totalExpectedBytes,
          chunkTimeout: const Duration(
            seconds: AppConstants.transferTimeoutSeconds,
          ),
          isCancelled: () => _isCancelled || _isActiveTransferCancelled,
          onProgress: (deltaBytes, activeFileName) {
            received += deltaBytes;
            speedTracker.recordBytes(deltaBytes, activeFileName, (speed, name) {
              onUpdate(
                TransferModel(
                  speed: speed,
                  transferred: received / 1024 / 1024,
                  fileName: name,
                  status: "Receiving files...",
                  totalSize: totalSizeMB,
                  progress: totalExpectedBytes > 0
                      ? received / totalExpectedBytes
                      : 0.0,
                  phase: TransferPhase.receiving,
                ),
              );
            });
          },
        );
        if (reverseConnectTarget == null) {
          try {
            final fastSrv = await ServerSocket.bind(
              InternetAddress.anyIPv4,
              0,
              shared: true,
            );
            v2Session.fastDataServer = fastSrv;
            v2Session.fastDataSub = fastSrv.listen(
              (Socket dataClient) {
                unawaited(() async {
                  final dataReader = BufferedSocketReader(dataClient);
                  try {
                    final headerResult = await dataReader.readJsonHeader(
                      maxHeaderBytes: 64 * 1024,
                      timeout: const Duration(
                        seconds: AppConstants.transferTimeoutSeconds,
                      ),
                    );
                    if (headerResult == null) {
                      await dataReader.cancel();
                      dataClient.destroy();
                      return;
                    }
                    final Map<String, dynamic> hdr = headerResult.header;
                    if (hdr["role"] != "data" ||
                        hdr["sessionId"] != v2Session!.sessionId ||
                        v2Session.aborted) {
                      try {
                        dataClient.write(
                          "${jsonEncode({"status": "REJECTED", "reason": "INVALID_SESSION"})}\n",
                        );
                        await dataClient.flush();
                      } catch (_) {}
                      await dataReader.cancel();
                      dataClient.destroy();
                      return;
                    }
                    await v2Session.runWorkerConnection(
                      socket: dataClient,
                      reader: dataReader,
                    );
                  } catch (_) {
                    await dataReader.cancel();
                    dataClient.destroy();
                  }
                }());
              },
              onError: (_) {},
              cancelOnError: false,
            );
          } catch (_) {}
        }
        _activeV2Session = v2Session;
      }

      String? receiverProof;
      if (localIdentity != null &&
          reverseConnectTarget != null &&
          isTlsConnection &&
          requestedVersion >= 2) {
        final serverFpForReady =
            reverseConnectTarget.expectedFingerprint?.trim().toLowerCase() ?? '';
        if (serverFpForReady.length == 64) {
          final proofMsg = DeviceIdentityService.buildAuthProofMessage(
            sessionId: sessionId ?? 'v2',
            senderPeerId: localIdentity.peerId,
            senderFingerprint: localIdentity.certFingerprint,
            serverFingerprint: serverFpForReady,
          );
          receiverProof = DeviceIdentityService.signAuthProof(
            privateKeyPem: localIdentity.privateKeyPem,
            message: proofMsg,
          );
        }
      }

      final int? readyFreqMhz = directFrequencyProvider?.call();
      final int? readyFastDataPort = v2Session?.fastDataServer?.port;
      try {
        client.write(
          '${jsonEncode({
            "s": "r",
            if (requestedVersion >= 2) "v": 2,
            if (requestedVersion >= 2) "streams": acceptedStreams,
            if (readyFastDataPort != null && readyFastDataPort > 0)
              "dataPort": readyFastDataPort,
            if (readyFreqMhz != null && readyFreqMhz > 0) "freqMhz": readyFreqMhz,
            if (requestedVersion >= 2 && localIdentity != null)
              "receiverPeerId": localIdentity.peerId,
            if (requestedVersion >= 2 && localIdentity != null)
              "receiverFp": localIdentity.certFingerprint,
            if (receiverProof != null && localIdentity != null)
              "receiverCertPem": localIdentity.certificatePem,
            "receiverProof": ?receiverProof,
          })}\n',
        );
        await client.flush();
        stopwatch.start();
      } catch (_) {
        throw "Sender disconnected before starting.";
      }

      if (v2Session != null) {
        final activeV2 = v2Session;
        if (reverseConnectTarget != null) {
          final int? fastDataPort = (metadata["dataPort"] as num?)?.toInt();
          final bool useFastRawData =
              fastDataPort != null && fastDataPort > 0;
          if (!useFastRawData &&
              reverseConnectTarget.useTls &&
              (reverseConnectTarget.expectedFingerprint == null ||
                  reverseConnectTarget.expectedFingerprint!.isEmpty)) {
            throw const HandshakeException(
              'Reverse data workers require a pinned sender certificate',
            );
          }
          for (var w = 0; w < acceptedStreams; w++) {
            final workerIdx = w;
            unawaited(() async {
              try {
                final workerSocket = await connectTransferSocket(
                  host: reverseConnectTarget.ip,
                  port: useFastRawData ? fastDataPort : reverseConnectTarget.port,
                  useTls: useFastRawData ? false : reverseConnectTarget.useTls,
                  timeout: const Duration(seconds: 15),
                  expectedPeerFingerprint: useFastRawData
                      ? null
                      : reverseConnectTarget.expectedFingerprint,
                );
                workerSocket.write(
                  '${jsonEncode({
                    "v": 2,
                    "role": "data",
                    "sessionId": sessionId,
                    "workerIndex": workerIdx,
                    if (reverseConnectTarget.reverseToken != null &&
                        reverseConnectTarget.reverseToken!.isNotEmpty)
                      "reverseToken": reverseConnectTarget.reverseToken,
                  })}\n',
                );
                await workerSocket.flush();
                await activeV2.runWorkerConnection(
                  socket: workerSocket,
                  reader: BufferedSocketReader(workerSocket),
                );
              } catch (e) {
                if (!activeV2.aborted && !activeV2.completedCleanly) {
                  await activeV2.abort();
                }
              }
            }());
          }
        }

        // Watch Control socket for premature disconnect/abort while workers transfer.
        unawaited(
          reader.drainLines(
            onLine: (line) {
              try {
                final decoded = jsonDecode(line);
                if (decoded is Map && decoded["status"] == "REJECTED") {
                  unawaited(activeV2.abort());
                }
              } catch (_) {}
            },
            onError: (_) {
              if (!activeV2.completedCleanly) {
                unawaited(activeV2.abort());
              }
            },
            onDone: () {
              if (!activeV2.completedCleanly) {
                unawaited(activeV2.abort());
              }
            },
          ),
        );

        await v2Session.awaitWorkers(
          idleConnectTimeout: Duration(
            seconds: reverseConnectTarget != null ? 15 : 10,
          ),
        );

        currentPhase = TransferPhase.finalizing;
        onUpdate(
          TransferModel(
            status: "Finishing up...",
            transferred: received / 1024 / 1024,
            totalSize: totalSizeMB,
            progress: 1.0,
            fileName: originalName ?? "",
            phase: TransferPhase.finalizing,
          ),
        );

        await v2Session.finalizeAndVerify();

        // Finalize any 0-byte files in the batch only after workers complete cleanly
        // so aborted or rejected transfers never leave empty stray files behind.
        for (final entry in rawFiles) {
          if (_isCancelled || _isActiveTransferCancelled) break;
          if ((entry["size"] as int) == 0) {
            final zeroPath = _resolveContainmentCheckedPath(
              saveDirectory,
              entry["path"] as String,
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
          }
        }
        if (closeFutures.isNotEmpty) {
          await Future.wait(closeFutures);
          closeFutures.clear();
        }
      } else {
        // Legacy v1 single-stream payload pipeline
        int currentFileIndex = await _drainZeroByteFiles(
          files: rawFiles,
          currentFileIndex: 0,
          saveDirectory: saveDirectory,
          createdDirs: createdDirs,
          closeFutures: closeFutures,
        );

        int bytesReadForCurrentFile = 0;
        IOSink? currentSink;
        BytesBuilder? currentBuffer;
        String? currentSavePath;
        String? currentPartialPath;

        Future<void> processPayloadChunk(Uint8List chunk) async {
          int offset = 0;
          while (offset < chunk.length && currentFileIndex < rawFiles.length) {
            final fileMeta = rawFiles[currentFileIndex];
            final int targetSize = fileMeta["size"] as int;

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
                _activePartialPaths.add(currentPartialPath!);
                currentSink = File(currentPartialPath!).openWrite();
                _activeSink = currentSink;
              }
            }

            final int remainingInChunk = chunk.length - offset;
            final int bytesNeeded = targetSize - bytesReadForCurrentFile;
            final int bytesToProcess = remainingInChunk <= bytesNeeded
                ? remainingInChunk
                : bytesNeeded;

            if (bytesToProcess > 0) {
              final slice = Uint8List.sublistView(
                chunk,
                offset,
                offset + bytesToProcess,
              );
              if (currentBuffer != null) {
                currentBuffer!.add(slice);
              } else if (currentSink != null) {
                currentSink!.add(slice);
              }
              bytesReadForCurrentFile += bytesToProcess;
              received += bytesToProcess;
              offset += bytesToProcess;
              speedTracker.recordBytes(
                bytesToProcess,
                p.basename(fileMeta["path"] as String),
                (speed, name) {
                  onUpdate(
                    TransferModel(
                      speed: speed,
                      transferred: received / 1024 / 1024,
                      fileName: name,
                      status: "Receiving Data...",
                      totalSize: totalSizeMB,
                      progress: totalExpectedBytes > 0
                          ? received / totalExpectedBytes
                          : 0.0,
                      phase: TransferPhase.receiving,
                    ),
                  );
                },
              );
            }

            if (bytesReadForCurrentFile == targetSize) {
              final String targetPath = currentSavePath!;
              final String partialPath = currentPartialPath!;
              currentSavePath = null;
              currentPartialPath = null;

              if (currentBuffer != null) {
                final bufferToSave = currentBuffer!;
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
                final sinkToClose = currentSink!;
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

              if (closeFutures.length >= 64) {
                await Future.wait(closeFutures);
                closeFutures.clear();
              }

              bytesReadForCurrentFile = 0;
              currentFileIndex++;

              currentFileIndex = await _drainZeroByteFiles(
                files: rawFiles,
                currentFileIndex: currentFileIndex,
                saveDirectory: saveDirectory,
                createdDirs: createdDirs,
                closeFutures: closeFutures,
              );
            }
          }
        }

        if (currentFileIndex < rawFiles.length) {
          if (initialPayload.isNotEmpty) {
            await processPayloadChunk(initialPayload);
          }

          while (currentFileIndex < rawFiles.length &&
              !_isCancelled &&
              !_isActiveTransferCancelled) {
            final hasNext = await reader.moveNext(
              timeout: const Duration(
                seconds: AppConstants.transferTimeoutSeconds,
              ),
            );
            if (!hasNext) break;
            await processPayloadChunk(reader.current);
          }
        }

        if (isRejected) return;

        if (_isCancelled || _isActiveTransferCancelled) {
          if (currentSink != null) {
            final sink = currentSink;
            currentSink = null;
            if (identical(_activeSink, sink)) _activeSink = null;
            try {
              await sink!.close();
            } catch (_) {}
          }
          throw _activeTransferCancelReason ??
              _cancelReason ??
              "Transfer Cancelled";
        }

        if (received < totalExpectedBytes) {
          if (currentSink != null) {
            final sink = currentSink;
            currentSink = null;
            if (identical(_activeSink, sink)) _activeSink = null;
            try {
              await sink!.close();
            } catch (_) {}
          }
          currentBuffer = null;
          throw "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}";
        }

        if (currentFileIndex < rawFiles.length &&
            (currentBuffer != null || currentSink != null)) {
          final int targetSize = rawFiles[currentFileIndex]["size"] as int;
          if (bytesReadForCurrentFile == targetSize &&
              currentSavePath != null &&
              currentPartialPath != null) {
            final String targetPath = currentSavePath!;
            final String partialPath = currentPartialPath!;
            currentSavePath = null;
            currentPartialPath = null;

            if (currentBuffer != null) {
              final bufferToSave = currentBuffer!;
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
              final sinkToClose = currentSink!;
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

        currentFileIndex = await _drainZeroByteFiles(
          files: rawFiles,
          currentFileIndex: currentFileIndex,
          saveDirectory: saveDirectory,
          createdDirs: createdDirs,
          closeFutures: closeFutures,
        );
        if (currentFileIndex < rawFiles.length) {
          throw "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}";
        }

        if (closeFutures.isNotEmpty) {
          currentPhase = TransferPhase.finalizing;
          onUpdate(
            TransferModel(
              status: "Finishing up...",
              transferred: received / 1024 / 1024,
              totalSize: totalSizeMB,
              progress: 1.0,
              fileName: originalName ?? "",
              phase: TransferPhase.finalizing,
            ),
          );
          await Future.wait(closeFutures);
          closeFutures.clear();
        }
      }

      try {
        client.write('${jsonEncode({"s": "d"})}\n');
        await client.flush();
      } catch (_) {}

      stopwatch.stop();
      final double finalMB = received / 1024 / 1024;
      final double elapsedSec = stopwatch.elapsedMilliseconds / 1000.0;
      final double avgSpeed = elapsedSec > 0.001 ? (finalMB / elapsedSec) : 0.0;
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
      if (v2Session != null && !v2Session.completedCleanly) {
        await v2Session.abort();
      }

      if (_isCancelled || _isActiveTransferCancelled || e is TimeoutException) {
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
      } else if (e.toString().toLowerCase().contains('transfer cancelled')) {
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
            progress:
                totalExpectedBytes > 0 ? received / totalExpectedBytes : 0.0,
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
            progress:
                totalExpectedBytes > 0 ? received / totalExpectedBytes : 0.0,
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
            progress:
                totalExpectedBytes > 0 ? received / totalExpectedBytes : 0.0,
            fileName: originalName ?? "",
            phase: currentPhase,
          ),
        );
      } else if (e is TimeoutException) {
        onUpdate(
          TransferModel(
            status:
                "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}.",
            transferred: received / 1024 / 1024,
            totalSize: totalExpectedBytes / 1024 / 1024,
            progress:
                totalExpectedBytes > 0 ? received / totalExpectedBytes : 0.0,
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
            progress:
                totalExpectedBytes > 0 ? received / totalExpectedBytes : 0.0,
            fileName: originalName ?? "",
            phase: currentPhase,
          ),
        );
      }
    } finally {
      try {
        onAuthDismissed?.call();
        if (_activeSink != null) {
          try {
            await _activeSink!.close();
          } catch (_) {}
          _activeSink = null;
        }
        if (v2Session != null && !v2Session.completedCleanly) {
          await v2Session.abort();
        }
        for (final partial in _activePartialPaths.toList()) {
          _safeDeleteFile(partial);
        }
        _activePartialPaths.clear();
        if (_activePartialPath != null) {
          _safeDeleteFile(_activePartialPath!);
          _activePartialPath = null;
        }
        await reader.cancel();
      } catch (_) {}
      if (identical(_activeV2Session, v2Session)) {
        _activeV2Session = null;
      }
      _activeAuthDismissCallback = null;
      _activeClient = null;
      _activeClientReader = null;
      _activeSink = null;
      _hasActiveTransfer = false;
      try {
        await waitForPendingRejection();
        if (!identical(_closingRejectionSocket, client)) {
          client.destroy();
        }
      } catch (_) {}
    }
  }

  void _handleOuterReceiverError(Object e, Function(TransferModel) onUpdate) {
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
            status: "Connection lost. Please check your Wi-Fi or Hotspot connection.",
            phase: TransferPhase.failed,
          ),
        );
      }
    } else if (e is TimeoutException) {
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
          status: "Error: $e",
          phase: currentPhase,
        ),
      );
    }
  }

  Future<void> _closeServers() async {
    try {
      await _plainServer?.close();
    } catch (_) {}
    try {
      await _secureServer?.close();
    } catch (_) {}
    _plainServer = null;
    _secureServer = null;
  }

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
      final String sanitizedRoot =
          originalName != null && originalName.isNotEmpty
              ? _sanitizeFileName(originalName)
              : p.posix.split(safeRel).first;
      files[0]["path"] = _generateUniquePath(saveDirectory, sanitizedRoot);
      return;
    }

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

    final Set<String> seenTargetsLower = {};
    for (int i = 0; i < files.length; i++) {
      final segments = parsedSegments[i];
      segments[0] = rootRemap[segments.first]!;
      String candidateRel = segments.join('/');

      if (!seenTargetsLower.add(candidateRel.toLowerCase())) {
        final parentIdx = candidateRel.lastIndexOf('/');
        final parent =
            parentIdx >= 0 ? candidateRel.substring(0, parentIdx + 1) : '';
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

  /// Sends a REJECTED control frame and flushes/closes TLS cleanly before destroy
  /// so the sender observes the rejection instead of racing an abrupt RST or
  /// premature Direct Wi-Fi teardown.
  Future<void> _sendRejectionAndClose(
    Socket client, {
    String? reason,
    bool backgroundLinger = false,
  }) async {
    _closingRejectionSocket = client;
    bool flushed = false;
    bool timedOut = false;
    try {
      client.write(
        '${jsonEncode({"status": "REJECTED", "reason": ?reason})}\n',
      );
      await client.flush().timeout(
        const Duration(milliseconds: 250),
        onTimeout: () {
          timedOut = true;
        },
      );
      flushed = !timedOut;
      await client.close().timeout(
        const Duration(milliseconds: 200),
        onTimeout: () {},
      );
    } catch (_) {}

    Future<void> finishClose() async {
      if (flushed) {
        await Future.any<void>(<Future<void>>[
          client.done.then<void>((_) {}, onError: (_) {}),
          Future<void>.delayed(const Duration(milliseconds: 120)),
        ]);
      }
      try {
        client.destroy();
      } catch (_) {}
      if (identical(_closingRejectionSocket, client)) {
        _closingRejectionSocket = null;
      }
    }

    if (backgroundLinger) {
      final Future<void> linger = finishClose();
      _pendingRejectionFuture = linger;
      unawaited(linger);
      return;
    }
    await finishClose();
  }

  void _abortActiveControlAndWorkers({String rejectionReason = "CANCELLED"}) {
    _activeAuthDismissCallback?.call();

    // Flush REJECTED on the control socket BEFORE aborting v2 data workers so
    // callers waiting on session end / Wi-Fi teardown don't cut L2 mid-flight.
    final activeClient = _activeClient;
    _activeClient = null;
    if (activeClient != null) {
      final Future<void> rejection =
          _sendRejectionAndClose(activeClient, reason: rejectionReason);
      _pendingRejectionFuture = rejection;
      unawaited(rejection);
    }

    unawaited(_activeV2Session?.abort());

    unawaited(_activeClientReader?.cancel());
    _activeClientReader = null;
    _activeSink?.close();
    _activeSink = null;
  }

  /// Cancels only the active transfer connection without stopping the server.
  void cancelActiveTransfer({String? reason}) {
    _isActiveTransferCancelled = true;
    _activeTransferCancelReason = reason;
    _abortActiveControlAndWorkers();
  }

  /// Stops the receiver server and cancels any active transfer.
  void stop({String? reason}) {
    _isCancelled = true;
    _cancelReason = reason;
    _isActiveTransferCancelled = true;
    _activeTransferCancelReason = reason;
    _abortActiveControlAndWorkers();
    _plainServer?.close();
    _secureServer?.close();
    _plainServer = null;
    _secureServer = null;
  }

  String _mapReceiverSocketError(SocketException e) {
    final msg = e.message.toLowerCase();
    final osError = e.osError?.errorCode;
    if (osError == 104 ||
        osError == 10054 ||
        osError == 32 ||
        msg.contains("connection reset by peer")) {
      return "Transfer cancelled by ${_currentSenderDeviceName ?? 'the other device'}.";
    } else {
      return "Connection lost. Please check your Wi-Fi or Hotspot connection.";
    }
  }

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

  static String _sanitizeFileName(String name) {
    String sanitized = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');

    final reserved = RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$',
      caseSensitive: false,
    );
    if (reserved.hasMatch(sanitized)) {
      sanitized = "file_$sanitized";
    }

    if (sanitized.isEmpty || sanitized.trim().replaceAll('.', '').isEmpty) {
      sanitized = "received_file_${++_fallbackNameCounter}";
    }

    return sanitized;
  }

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
