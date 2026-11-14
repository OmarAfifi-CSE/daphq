import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const int daphqChunkMagic = 0x44514332; // 'DQC2'
const int daphqEofFileIndex = 0xFFFFFFFF;
const int daphqFrameHeaderSize = 20;
const int daphqChunkSizeBytes = 256 * 1024; // 256 KB parallel work unit
const int daphqMaxFramePayloadBytes = 8 * 1024 * 1024;

/// Detailed incoming transfer authentication metadata passed to v2 auth handlers.
class TransferAuthRequest {
  final String senderIp;
  final String senderDeviceName;
  final int fileCount;
  final double totalSizeMB;
  final String? senderPeerId;
  final String? senderFingerprint;
  final String? sasCode;
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
    this.sasCode,
    this.isTls = false,
    this.isReverseConnect = false,
    this.isIdentityVerified = false,
  });
}

String generateTransferSessionId() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

Uint8List buildV2FrameHeader({
  required int fileIndex,
  required int fileOffset,
  required int payloadLength,
}) {
  final bytes = Uint8List(daphqFrameHeaderSize);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, daphqChunkMagic, Endian.big);
  view.setUint32(4, fileIndex, Endian.big);
  view.setUint64(8, fileOffset, Endian.big);
  view.setUint32(16, payloadLength, Endian.big);
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

/// Binds a TCP or TLS server socket across anyIPv4 with per-interface fallback.
Future<({ServerSocket? plain, SecureServerSocket? secure})> bindTransferServer({
  required int port,
  required Duration retryDelay,
  required int maxAttempts,
  required bool Function() isCancelled,
  required void Function(int attempt, int totalAttempts) onAttempt,
  SecurityContext? tlsContext,
}) async {
  int attempts = 0;
  Object? lastError;

  while (attempts < maxAttempts && !isCancelled()) {
    onAttempt(attempts + 1, maxAttempts);
    try {
      if (tlsContext != null) {
        final srv = await SecureServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          tlsContext,
          shared: true,
        );
        return (plain: null, secure: srv);
      } else {
        final srv = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
        return (plain: srv, secure: null);
      }
    } catch (e) {
      lastError = e;
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        );
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback) {
              try {
                if (tlsContext != null) {
                  final srv = await SecureServerSocket.bind(
                    addr,
                    port,
                    tlsContext,
                    shared: true,
                  );
                  return (plain: null, secure: srv);
                } else {
                  final srv = await ServerSocket.bind(addr, port, shared: true);
                  return (plain: srv, secure: null);
                }
              } catch (_) {}
            }
          }
        }
      } catch (_) {}

      attempts++;
      if (attempts < maxAttempts && !isCancelled()) {
        await Future.delayed(retryDelay);
      }
    }
  }

  if (lastError != null && !isCancelled()) {
    throw lastError;
  }
  return (plain: null, secure: null);
}

/// Helper that reads an initial newline-delimited JSON header without losing trailing payload bytes.
class BufferedSocketReader {
  final StreamIterator<Uint8List> _iterator;
  Uint8List _leftover = Uint8List(0);

  BufferedSocketReader(Socket socket)
      : _iterator = StreamIterator<Uint8List>(socket);

  Future<({Map<String, dynamic> header, Uint8List initialPayload})?>
      readJsonHeader({
    required int maxHeaderBytes,
    required Duration timeout,
  }) async {
    final buffer = BytesBuilder(copy: false);
    final deadline = DateTime.now().add(timeout);

    while (await _moveNextWithDeadline(deadline)) {
      final chunk = _iterator.current;
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
    if (timeout == null) {
      return _iterator.moveNext();
    }
    return _iterator.moveNext().timeout(timeout);
  }

  Uint8List get current => _iterator.current;

  /// Consumes newline-delimited UTF-8 lines using the single underlying [StreamIterator]
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
      while (await _iterator.moveNext()) {
        lineBuffer.addAll(_iterator.current);
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
    try {
      await _iterator.cancel();
    } catch (_) {}
  }

  Future<bool> _moveNextWithDeadline(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Header read timed out');
    }
    return _iterator.moveNext().timeout(remaining);
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
  required Future<void> Function(int fileIndex, int offset, Uint8List payload)
      onChunk,
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
          await onChunk(currentFileIndex, currentOffset, completedPayload);
        }
      }
    }
  }

  final initial = reader.takeLeftover();
  if (initial.isNotEmpty) {
    await processChunkBytes(initial);
  }

  while (!sawEof && !isCancelled()) {
    final hasNext = await reader.moveNext(timeout: chunkTimeout);
    if (!hasNext) break;
    await processChunkBytes(reader.current);
  }

  if (!sawEof && !isCancelled() && (headerFilled > 0 || payloadBuf != null)) {
    throw const SocketException('Worker stream terminated mid-frame');
  }
}
