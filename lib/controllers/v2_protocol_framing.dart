import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/app_constants.dart';
import '../security/device_identity_service.dart';

const int daphqChunkMagic = 0x44514332; // 'DQC2'
const int daphqEofFileIndex = 0xFFFFFFFF;
const int daphqFrameHeaderSize = 20;
const int daphqChunkSizeBytes = 512 * 1024; // 512 KB parallel work unit
const int daphqMaxFramePayloadBytes = 8 * 1024 * 1024;

/// Detailed incoming transfer authentication metadata passed to v2 auth handlers.
class TransferAuthRequest {
  final String senderIp;
  final String senderDeviceName;
  final int fileCount;
  final double totalSizeMB;
  final String? senderPeerId;
  final String? senderFingerprint;
  final bool isTls;
  final bool isReverseConnect;
  final bool isIdentityVerified;

  const TransferAuthRequest({
    required this.senderIp,
    required this.senderDeviceName,
    required this.fileCount,
    required this.totalSizeMB,
    this.senderPeerId,
    this.senderFingerprint,
    this.isTls = false,
    this.isReverseConnect = false,
    this.isIdentityVerified = false,
  });
}

/// Signed LAN control-plane message (`role: "direct_control"`) used to bootstrap a
/// Direct 5GHz Wi-Fi P2P / SoftAP link between router-connected peers without Bluetooth.
class DirectControlRequest {
  final String requestId;
  final String senderIp;
  final String senderPeerId;
  final String senderDeviceName;
  final String? senderFingerprint;
  final String action; // 'startHostAndWait' | 'joinHost' | 'teardown'
  final String? ssid;
  final String? psk;
  final String? hostIp;
  final int port;
  final bool useReverseConnect;
  final int? frequencyMhz;
  final String? reverseToken;
  final bool isIdentityVerified;

  const DirectControlRequest({
    required this.requestId,
    required this.senderIp,
    required this.senderPeerId,
    required this.senderDeviceName,
    this.senderFingerprint,
    required this.action,
    this.ssid,
    this.psk,
    this.hostIp,
    this.port = 62004,
    this.useReverseConnect = false,
    this.frequencyMhz,
    this.reverseToken,
    this.isIdentityVerified = false,
  });
}

/// Sends an ECDSA-signed TLS control request over LAN to negotiate a Direct 5GHz session.
Future<Map<String, dynamic>> sendDirectControl({
  required String host,
  required int port,
  required DeviceIdentity localIdentity,
  required String localDeviceName,
  required int localPort,
  required String action,
  String? expectedPeerFingerprint,
  Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
  String? ssid,
  String? psk,
  String? hostIp,
  bool reverseConnect = false,
  int? frequencyMhz,
  String? reverseToken,
  Duration connectTimeout = const Duration(seconds: 4),
  Duration responseTimeout = const Duration(seconds: 15),
}) async {
  String? verifiedServerFp = expectedPeerFingerprint?.trim().toLowerCase();
  final Socket sock = await connectTransferSocket(
    host: host,
    port: port,
    useTls: true,
    timeout: connectTimeout,
    expectedPeerFingerprint: expectedPeerFingerprint,
    onVerifyPeerFingerprint: (actualFp) async {
      verifiedServerFp = actualFp.trim().toLowerCase();
      if (onVerifyPeerFingerprint != null) {
        return onVerifyPeerFingerprint(actualFp);
      }
      return true;
    },
  );

  final reader = BufferedSocketReader(sock);
  try {
    final String serverFp = verifiedServerFp ??
        ((sock is SecureSocket && sock.peerCertificate != null)
            ? DeviceIdentityService.fingerprintFromCertificate(
                sock.peerCertificate!,
              )
            : '');
    if (serverFp.isEmpty) {
      throw const HandshakeException('Missing server certificate fingerprint');
    }

    final requestId = generateTransferSessionId();
    final msg = DeviceIdentityService.buildAuthProofMessage(
      sessionId: requestId,
      senderPeerId: localIdentity.peerId,
      senderFingerprint: localIdentity.certFingerprint,
      serverFingerprint: serverFp,
    );
    final proof = DeviceIdentityService.signAuthProof(
      privateKeyPem: localIdentity.privateKeyPem,
      message: msg,
    );

    final payload = <String, dynamic>{
      'v': 2,
      'role': 'direct_control',
      'requestId': requestId,
      'action': action,
      'peerId': localIdentity.peerId,
      'peerName': localDeviceName,
      'senderFp': localIdentity.certFingerprint,
      'senderCertPem': localIdentity.certificatePem,
      'senderProof': proof,
      'port': localPort,
      'reverseConnect': reverseConnect,
      'ssid': ?ssid,
      'psk': ?psk,
      'hostIp': ?hostIp,
      'frequencyMhz': ?frequencyMhz,
      'reverseToken': ?reverseToken,
    };

    sock.write('${jsonEncode(payload)}\n');
    await sock.flush();

    final resp = await reader.readJsonHeader(
      maxHeaderBytes: 64 * 1024,
      timeout: responseTimeout,
    );
    return resp?.header ??
        <String, dynamic>{'ok': false, 'error': 'emptyResponse'};
  } finally {
    await reader.cancel();
    sock.destroy();
  }
}

String generateTransferSessionId() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// Writes a 20-byte v2 frame header directly into [target] starting at
/// [offsetBytes], avoiding a separate header allocation and socket write.
void writeV2FrameHeaderTo(
  Uint8List target, {
  int offsetBytes = 0,
  required int fileIndex,
  required int fileOffset,
  required int payloadLength,
}) {
  final view = ByteData.sublistView(
    target,
    offsetBytes,
    offsetBytes + daphqFrameHeaderSize,
  );
  view.setUint32(0, daphqChunkMagic, Endian.big);
  view.setUint32(4, fileIndex, Endian.big);
  view.setUint64(8, fileOffset, Endian.big);
  view.setUint32(16, payloadLength, Endian.big);
}

Uint8List buildV2FrameHeader({
  required int fileIndex,
  required int fileOffset,
  required int payloadLength,
}) {
  final bytes = Uint8List(daphqFrameHeaderSize);
  writeV2FrameHeaderTo(
    bytes,
    fileIndex: fileIndex,
    fileOffset: fileOffset,
    payloadLength: payloadLength,
  );
  return bytes;
}

Uint8List buildV2EofFrame() {
  return buildV2FrameHeader(
    fileIndex: daphqEofFileIndex,
    fileOffset: 0,
    payloadLength: 0,
  );
}

/// Connects a TCP or TLS-pinned socket cleanly.
Future<Socket> connectTransferSocket({
  required String host,
  required int port,
  required bool useTls,
  required Duration timeout,
  String? expectedPeerFingerprint,
  Future<bool> Function(String actualFingerprint)? onVerifyPeerFingerprint,
}) async {
  if (!useTls) {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return socket;
  }

  final expectedNorm = expectedPeerFingerprint?.trim().toLowerCase();
  final bool hasExpected = expectedNorm != null && expectedNorm.isNotEmpty;
  if (!hasExpected && onVerifyPeerFingerprint == null) {
    throw const HandshakeException(
      'TLS transfer connection requires expectedPeerFingerprint or verifier',
    );
  }

  String? observedFingerprint;

  final secureSocket = await SecureSocket.connect(
    host,
    port,
    timeout: timeout,
    onBadCertificate: (X509Certificate cert) {
      observedFingerprint = sha256.convert(cert.der).toString().toLowerCase();
      if (hasExpected) {
        return observedFingerprint == expectedNorm;
      }
      // Validated immediately after handshake by onVerifyPeerFingerprint below.
      return onVerifyPeerFingerprint != null;
    },
  );

  secureSocket.setOption(SocketOption.tcpNoDelay, true);

  final peerCert = secureSocket.peerCertificate;
  final actualCertFp = peerCert != null
      ? sha256.convert(peerCert.der).toString().toLowerCase()
      : (observedFingerprint ?? '');
  if (actualCertFp.isEmpty) {
    secureSocket.destroy();
    throw const HandshakeException('Missing peer TLS certificate');
  }

  if (hasExpected && actualCertFp != expectedNorm) {
    secureSocket.destroy();
    throw const HandshakeException(
      'Peer certificate fingerprint mismatch',
    );
  }

  if (onVerifyPeerFingerprint != null) {
    final allowed = await onVerifyPeerFingerprint(actualCertFp);
    if (!allowed) {
      secureSocket.destroy();
      throw const HandshakeException(
        'Peer TLS certificate rejected by trust policy',
      );
    }
  }

  return secureSocket;
}

Future<({ServerSocket? plain, SecureServerSocket? secure})> _bindSingleTransferPort({
  required int port,
  SecurityContext? tlsContext,
  required Future<ServerSocket> Function(
    dynamic address,
    int port, {
    bool shared,
  }) plainBind,
  required Future<SecureServerSocket> Function(
    dynamic address,
    int port,
    SecurityContext context, {
    bool shared,
  }) secureBind,
}) async {
  try {
    if (tlsContext != null) {
      final srv = await secureBind(
        InternetAddress.anyIPv4,
        port,
        tlsContext,
        shared: true,
      );
      return (plain: null, secure: srv);
    }
    final srv = await plainBind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    return (plain: srv, secure: null);
  } catch (e) {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            try {
              if (tlsContext != null) {
                final srv = await secureBind(
                  addr,
                  port,
                  tlsContext,
                  shared: true,
                );
                return (plain: null, secure: srv);
              }
              final srv = await plainBind(addr, port, shared: true);
              return (plain: srv, secure: null);
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    rethrow;
  }
}

/// Binds a TCP or TLS server socket across anyIPv4 with per-interface and port fallbacks.
Future<({ServerSocket? plain, SecureServerSocket? secure})> bindTransferServer({
  required int port,
  required Duration retryDelay,
  required int maxAttempts,
  required bool Function() isCancelled,
  required void Function(int attempt, int totalAttempts) onAttempt,
  SecurityContext? tlsContext,
  List<int> fallbackPorts = const <int>[],
  Future<ServerSocket> Function(dynamic address, int port, {bool shared})?
      plainBinder,
  Future<SecureServerSocket> Function(
    dynamic address,
    int port,
    SecurityContext context, {
    bool shared,
  })? secureBinder,
}) async {
  final Future<ServerSocket> Function(dynamic, int, {bool shared}) plainBind =
      plainBinder ??
      ((dynamic address, int port, {bool shared = true}) =>
          ServerSocket.bind(address, port, shared: shared));
  final Future<SecureServerSocket> Function(
    dynamic,
    int,
    SecurityContext, {
    bool shared,
  }) secureBind = secureBinder ??
      ((dynamic address, int port, SecurityContext context, {bool shared = true}) =>
          SecureServerSocket.bind(address, port, context, shared: shared));

  final List<int> candidatePorts = port == 0
      ? const <int>[0]
      : <int>[
          port,
          for (final alt in fallbackPorts)
            if (alt > 0 && alt != port) alt,
        ];

  int attempts = 0;
  Object? lastError;

  while (attempts < maxAttempts && !isCancelled()) {
    onAttempt(attempts + 1, maxAttempts);
    for (final candidatePort in candidatePorts) {
      if (isCancelled()) break;
      try {
        return await _bindSingleTransferPort(
          port: candidatePort,
          tlsContext: tlsContext,
          plainBind: plainBind,
          secureBind: secureBind,
        );
      } catch (e) {
        lastError = e;
      }
    }

    attempts++;
    if (attempts < maxAttempts && !isCancelled()) {
      await Future.delayed(retryDelay);
    }
  }

  if (lastError != null && !isCancelled()) {
    throw lastError;
  }
  return (plain: null, secure: null);
}

/// Helper that reads an initial newline-delimited JSON header without losing trailing payload bytes,
/// backed by a non-pausing push queue so high-rate TCP/TLS streams never suffer per-packet
/// `StreamIterator` pause/resume syscalls or per-packet `Timer` allocations.
class BufferedSocketReader {
  static const int _highWaterMarkBytes = 32 * 1024 * 1024;
  static const int _lowWaterMarkBytes = 16 * 1024 * 1024;

  StreamSubscription<Uint8List>? _sub;
  final ListQueue<Uint8List> _queue = ListQueue<Uint8List>();
  int _queuedBytes = 0;
  bool _subPaused = false;
  bool _isDone = false;
  Object? _error;
  StackTrace? _errorStack;
  Completer<bool>? _waiter;
  Uint8List _current = Uint8List(0);
  Uint8List _leftover = Uint8List(0);

  BufferedSocketReader(Socket socket) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _sub = socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  void _onData(Uint8List data) {
    if (data.isEmpty) return;
    final waiter = _waiter;
    if (waiter != null && _queue.isEmpty) {
      _waiter = null;
      _current = data;
      waiter.complete(true);
      return;
    }
    _queue.addLast(data);
    _queuedBytes += data.length;
    if (!_subPaused && _queuedBytes >= _highWaterMarkBytes) {
      _subPaused = true;
      _sub?.pause();
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    _error = error;
    _errorStack = stackTrace;
    _isDone = true;
    final waiter = _waiter;
    if (waiter != null) {
      _waiter = null;
      waiter.completeError(error, stackTrace);
    }
  }

  void _onDone() {
    _isDone = true;
    final waiter = _waiter;
    if (waiter != null) {
      _waiter = null;
      waiter.complete(false);
    }
  }

  void _maybeResumeSub() {
    if (_subPaused && _queuedBytes <= _lowWaterMarkBytes && !_isDone) {
      _subPaused = false;
      _sub?.resume();
    }
  }

  /// Synchronously pops the next buffered socket chunk if one is already in memory,
  /// avoiding Future, Completer, Timer, and microtask overhead on the hot path.
  Uint8List? tryMoveNextSync() {
    if (_queue.isNotEmpty) {
      final chunk = _queue.removeFirst();
      _queuedBytes -= chunk.length;
      _current = chunk;
      _maybeResumeSub();
      return chunk;
    }
    return null;
  }

  Future<({Map<String, dynamic> header, Uint8List initialPayload})?>
      readJsonHeader({
    required int maxHeaderBytes,
    required Duration timeout,
  }) async {
    final buffer = BytesBuilder(copy: false);
    final deadline = DateTime.now().add(timeout);

    while (await _moveNextWithDeadline(deadline)) {
      final chunk = _current;
      final newlineIdx = chunk.indexOf(10); // '\n'
      if (newlineIdx != -1) {
        if (newlineIdx > 0) {
          buffer.add(Uint8List.sublistView(chunk, 0, newlineIdx));
        }
        if (buffer.length > maxHeaderBytes) {
          throw const FormatException('HEADER_TOO_LARGE');
        }
        final headerText = utf8.decode(buffer.takeBytes()).trim();
        final decoded = jsonDecode(headerText);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('INVALID_HEADER');
        }
        final remaining = newlineIdx + 1 < chunk.length
            ? Uint8List.fromList(chunk.sublist(newlineIdx + 1))
            : Uint8List(0);
        _leftover = remaining;
        return (header: decoded, initialPayload: remaining);
      }

      buffer.add(chunk);
      if (buffer.length > maxHeaderBytes) {
        throw const FormatException('HEADER_TOO_LARGE');
      }
    }
    return null;
  }

  Uint8List takeLeftover() {
    final out = _leftover;
    _leftover = Uint8List(0);
    return out;
  }

  Future<bool> moveNext({Duration? timeout}) {
    final syncChunk = tryMoveNextSync();
    if (syncChunk != null) {
      return Future<bool>.value(true);
    }
    if (_error != null) {
      final err = _error!;
      final st = _errorStack;
      _error = null;
      _errorStack = null;
      return Future<bool>.error(err, st);
    }
    if (_isDone) {
      return Future<bool>.value(false);
    }
    final waiter = Completer<bool>();
    _waiter = waiter;
    if (timeout == null) {
      return waiter.future;
    }
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        if (identical(_waiter, waiter)) {
          _waiter = null;
        }
        throw TimeoutException('Socket read timed out', timeout);
      },
    );
  }

  Uint8List get current => _current;

  /// Consumes newline-delimited UTF-8 lines using the single underlying subscription
  /// (so callers never double-subscribe to a single-subscription [Socket] or [SecureSocket]).
  Future<void> drainLines({
    required void Function(String line) onLine,
    void Function(Object error)? onError,
    void Function()? onDone,
    int maxLineBytes = 1024 * 1024,
  }) async {
    final List<int> lineBuffer = <int>[];
    if (_leftover.isNotEmpty) {
      lineBuffer.addAll(_leftover);
      _leftover = Uint8List(0);
    }

    void flushLines() {
      while (true) {
        final idx = lineBuffer.indexOf(10); // '\n'
        if (idx == -1) {
          if (lineBuffer.length > maxLineBytes) {
            throw const FormatException('Control line exceeded maximum size');
          }
          break;
        }
        if (idx > maxLineBytes) {
          throw const FormatException('Control line exceeded maximum size');
        }
        final line = utf8
            .decode(lineBuffer.sublist(0, idx), allowMalformed: true)
            .trim();
        lineBuffer.removeRange(0, idx + 1);
        if (line.isNotEmpty) {
          onLine(line);
        }
      }
    }

    try {
      flushLines();
      while (await moveNext()) {
        lineBuffer.addAll(_current);
        flushLines();
      }
      if (lineBuffer.isNotEmpty) {
        final trailing = utf8.decode(lineBuffer, allowMalformed: true).trim();
        lineBuffer.clear();
        if (trailing.isNotEmpty) {
          onLine(trailing);
        }
      }
      onDone?.call();
    } catch (e) {
      onError?.call(e);
    }
  }

  Future<void> cancel() async {
    _isDone = true;
    _queue.clear();
    _queuedBytes = 0;
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.complete(false);
    }
    final sub = _sub;
    _sub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
  }

  Future<bool> _moveNextWithDeadline(DateTime deadline) {
    final syncChunk = tryMoveNextSync();
    if (syncChunk != null) {
      return Future<bool>.value(true);
    }
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Header read timed out');
    }
    return moveNext(timeout: remaining);
  }
}

class ChunkTask {
  final int fileIndex;
  final String absPath;
  final int offset;
  final int length;
  final int totalFileSize;

  const ChunkTask({
    required this.fileIndex,
    required this.absPath,
    required this.offset,
    required this.length,
    required this.totalFileSize,
  });
}

/// Lock-free O(1)-memory work-stealing scheduler dividing non-empty files into chunks.
class ChunkWorkStealer {
  final List<Map<String, dynamic>> _files;
  final int _chunkSize;
  int _fileIndex = 0;
  int _offset = 0;

  ChunkWorkStealer(this._files, {int chunkSize = daphqChunkSizeBytes})
      : _chunkSize = chunkSize;

  ChunkTask? nextTask() {
    while (_fileIndex < _files.length) {
      final entry = _files[_fileIndex];
      final size = entry['size'] as int;
      if (size <= 0 || _offset >= size) {
        _fileIndex++;
        _offset = 0;
        continue;
      }

      final remaining = size - _offset;
      final len = remaining <= _chunkSize ? remaining : _chunkSize;
      final task = ChunkTask(
        fileIndex: _fileIndex,
        absPath: entry['absPath'] as String,
        offset: _offset,
        length: len,
        totalFileSize: size,
      );
      _offset += len;
      if (_offset >= size) {
        _fileIndex++;
        _offset = 0;
      }
      return task;
    }
    return null;
  }
}

/// Zero-copy-overhead framing parser for v2 worker sockets.
Future<void> consumeV2WorkerFrames({
  required BufferedSocketReader reader,
  required Duration chunkTimeout,
  required bool Function() isCancelled,
  required FutureOr<void> Function(
    int fileIndex,
    int offset,
    Uint8List payload,
  ) onChunk,
}) async {
  final headerBuf = Uint8List(daphqFrameHeaderSize);
  var headerFilled = 0;

  int currentFileIndex = 0;
  int currentOffset = 0;
  Uint8List? payloadBuf;
  int payloadFilled = 0;
  bool sawEof = false;

  Future<void> processChunkBytes(Uint8List chunk) async {
    var pos = 0;
    while (pos < chunk.length && !sawEof) {
      if (isCancelled()) return;

      if (payloadBuf == null) {
        final need = daphqFrameHeaderSize - headerFilled;
        final take = (chunk.length - pos) < need ? (chunk.length - pos) : need;
        headerBuf.setRange(headerFilled, headerFilled + take, chunk, pos);
        headerFilled += take;
        pos += take;

        if (headerFilled == daphqFrameHeaderSize) {
          final view = ByteData.sublistView(headerBuf);
          final magic = view.getUint32(0, Endian.big);
          if (magic != daphqChunkMagic) {
            throw const FormatException('Corrupt Daphq v2 chunk magic');
          }
          currentFileIndex = view.getUint32(4, Endian.big);
          currentOffset = view.getUint64(8, Endian.big);
          final payloadLen = view.getUint32(16, Endian.big);
          if (payloadLen > daphqMaxFramePayloadBytes) {
            throw const FormatException('Frame payload exceeds limit');
          }
          headerFilled = 0;

          if (currentFileIndex == daphqEofFileIndex && payloadLen == 0) {
            sawEof = true;
            return;
          }
          if (payloadLen == 0) {
            continue;
          }
          // Fast path: full frame payload is already contiguous in `chunk`
          if (chunk.length - pos >= payloadLen) {
            final completedPayload = Uint8List.sublistView(
              chunk,
              pos,
              pos + payloadLen,
            );
            pos += payloadLen;
            final res = onChunk(currentFileIndex, currentOffset, completedPayload);
            if (res is Future<void>) {
              await res;
            }
            continue;
          }
          payloadBuf = Uint8List(payloadLen);
          payloadFilled = 0;
        }
      } else {
        final need = payloadBuf!.length - payloadFilled;
        final take = (chunk.length - pos) < need ? (chunk.length - pos) : need;
        payloadBuf!.setRange(payloadFilled, payloadFilled + take, chunk, pos);
        payloadFilled += take;
        pos += take;

        if (payloadFilled == payloadBuf!.length) {
          final completedPayload = payloadBuf!;
          payloadBuf = null;
          payloadFilled = 0;
          final res = onChunk(currentFileIndex, currentOffset, completedPayload);
          if (res is Future<void>) {
            await res;
          }
        }
      }
    }
  }

  final initial = reader.takeLeftover();
  if (initial.isNotEmpty) {
    await processChunkBytes(initial);
  }

  while (!sawEof && !isCancelled()) {
    final syncChunk = reader.tryMoveNextSync();
    if (syncChunk != null) {
      await processChunkBytes(syncChunk);
      continue;
    }
    final hasNext = await reader.moveNext(timeout: chunkTimeout);
    if (!hasNext) break;
    await processChunkBytes(reader.current);
  }

  if (!sawEof && !isCancelled() && (headerFilled > 0 || payloadBuf != null)) {
    throw const SocketException('Worker stream terminated mid-frame');
  }
}

/// Shared EMA-smoothed speed tracker used by both sender and receiver transfer loops.
class TransferSpeedTracker {
  TransferSpeedTracker({
    DateTime Function()? nowProvider,
    this.intervalMs = AppConstants.speedUpdateIntervalMs,
    this.alpha = 0.35,
  }) : _nowProvider = nowProvider ?? DateTime.now {
    _lastEmit = _nowProvider();
  }

  final DateTime Function() _nowProvider;
  final int intervalMs;
  final double alpha;

  late DateTime _lastEmit;
  int _bytesSinceEmit = 0;
  double? _smoothedMbps;

  double get currentSpeedMbps => _smoothedMbps ?? 0.0;

  void recordBytes(
    int deltaBytes,
    String activeFileName,
    void Function(double speedMbps, String activeFileName) onEmit,
  ) {
    if (deltaBytes > 0) {
      _bytesSinceEmit += deltaBytes;
    }
    final now = _nowProvider();
    final elapsedMs = now.difference(_lastEmit).inMilliseconds;
    if (elapsedMs < intervalMs || elapsedMs <= 0) {
      return;
    }

    final instantMbps = (_bytesSinceEmit / (1024 * 1024)) / (elapsedMs / 1000.0);
    _smoothedMbps = _smoothedMbps == null
        ? instantMbps
        : (alpha * instantMbps) + ((1.0 - alpha) * _smoothedMbps!);
    _bytesSinceEmit = 0;
    _lastEmit = now;
    onEmit(_smoothedMbps!, activeFileName);
  }
}

/// Contiguous byte range dequeued from [V2OrderedChunkCoalescer] for sequential disk flush.
class CoalescedChunkBatch {
  const CoalescedChunkBatch({required this.offset, required this.bytes});

  final int offset;
  final Uint8List bytes;
}

/// Orders out-of-order multi-stream chunks and merges contiguous offsets into large
/// sequential write batches up to `maxBatchBytes` (default 2 MB).
class V2OrderedChunkCoalescer {
  final SplayTreeMap<int, Uint8List> _chunks = SplayTreeMap<int, Uint8List>();
  final List<({int start, int end})> _flushedRanges = <({int start, int end})>[];
  int _pendingBytes = 0;

  int get pendingBytes => _pendingBytes;
  bool get isEmpty => _chunks.isEmpty;

  int get nextInOrderOffset =>
      _flushedRanges.isNotEmpty && _flushedRanges.first.start == 0
          ? _flushedRanges.first.end
          : 0;

  void enqueue(int offset, Uint8List data) {
    final existing = _chunks[offset];
    if (existing != null) {
      _pendingBytes -= existing.length;
    }
    _chunks[offset] = data;
    _pendingBytes += data.length;
  }

  /// Dequeues contiguous chunks starting at `nextInOrderOffset` (or the lowest queued
  /// offset when [allowOutOfOrderFallback] is true) without allocating or copying a
  /// combined buffer when chunks are already large.
  ({int offset, List<Uint8List> parts, int totalBytes})? takeNextPartsList({
    int maxBatchBytes = 8 * 1024 * 1024,
    bool allowOutOfOrderFallback = false,
  }) {
    if (_chunks.isEmpty) return null;
    final inOrder = nextInOrderOffset;
    final int startOffset;
    if (_chunks.containsKey(inOrder)) {
      startOffset = inOrder;
    } else if (allowOutOfOrderFallback) {
      startOffset = _chunks.firstKey()!;
    } else {
      return null;
    }

    int cursor = startOffset;
    int totalLen = 0;
    final parts = <Uint8List>[];
    while (true) {
      final next = _chunks[cursor];
      if (next == null) break;
      if (parts.isNotEmpty && totalLen + next.length > maxBatchBytes) {
        break;
      }
      _chunks.remove(cursor);
      _pendingBytes -= next.length;
      parts.add(next);
      totalLen += next.length;
      cursor += next.length;
    }

    _recordFlushedRange(startOffset, cursor);
    return (offset: startOffset, parts: parts, totalBytes: totalLen);
  }

  CoalescedChunkBatch? takeNextBatch({
    int maxBatchBytes = 4 * 1024 * 1024,
    bool allowOutOfOrderFallback = false,
  }) {
    final res = takeNextPartsList(
      maxBatchBytes: maxBatchBytes,
      allowOutOfOrderFallback: allowOutOfOrderFallback,
    );
    if (res == null) return null;
    final parts = res.parts;
    if (parts.length == 1) {
      return CoalescedChunkBatch(offset: res.offset, bytes: parts.first);
    }

    final combined = Uint8List(res.totalBytes);
    var pos = 0;
    for (final part in parts) {
      combined.setAll(pos, part);
      pos += part.length;
    }
    return CoalescedChunkBatch(offset: res.offset, bytes: combined);
  }

  void clear() {
    _chunks.clear();
    _flushedRanges.clear();
    _pendingBytes = 0;
  }

  void _recordFlushedRange(int start, int end) {
    if (end <= start) return;
    _flushedRanges.add((start: start, end: end));
    _flushedRanges.sort((a, b) => a.start.compareTo(b.start));
    final merged = <({int start, int end})>[];
    for (final r in _flushedRanges) {
      if (merged.isEmpty || merged.last.end < r.start) {
        merged.add(r);
      } else {
        final prev = merged.removeLast();
        merged.add((
          start: prev.start,
          end: prev.end > r.end ? prev.end : r.end,
        ));
      }
    }
    _flushedRanges
      ..clear()
      ..addAll(merged);
  }
}
