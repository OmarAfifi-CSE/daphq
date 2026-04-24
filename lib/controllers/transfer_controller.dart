import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'package:path/path.dart' as p;
import '../models/transfer_model.dart';
import 'package:flutter/foundation.dart'; // import to detect platform
import 'dart:async';

class TransferController {
  static const int port = 9999;
  ServerSocket? _server;

  Socket? _activeSenderSocket;
  bool _isSenderCancelled = false;

  Socket? _activeReceiverClient;
  IOSink? _activeReceiverSink;
  bool _isReceiverCancelled = false;

  // --- SENDER (PC): The New Direct-Stream Protocol ---
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

      // 1. حصر الملفات وتجهيزها
      if (isFolder) {
        var dir = Directory(path);
        if (!dir.existsSync()) throw "Folder not found!";

        var entities = dir.listSync(recursive: true).whereType<File>();
        for (var f in entities) {
          int size = f.lengthSync();
          // توحيد شكل المسار عشان الأندرويد يفهم الفولدرات صح
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

      if (totalBytesToSend == 0)
        throw "Error: The selected item is empty (0.0 MB).";

      // 2. الاتصال بالموبايل
      onUpdate(TransferModel(status: "Connecting..."));
      final socket = await Socket.connect(
        targetIp,
        port,
        timeout: Duration(seconds: 5),
      );
      _activeSenderSocket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);

      // 3. إرسال خريطة الملفات (JSON Header)
      Map<String, dynamic> metadata = {
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

      // 3.5 Wait for Authorization
      onUpdate(TransferModel(status: "Waiting for Receiver to Accept..."));

      // Read a single line/response from the receiver
      String authResponse = "";
      try {
        final authData = await socket.first.timeout(
          const Duration(minutes: 1),
          onTimeout: () => throw "Timeout",
        );
        authResponse = utf8.decode(authData).trim();
      } catch (e) {
        throw "Receiver disconnected or timeout before answering.";
      }

      Map<String, dynamic>? authResObj;
      try {
        authResObj = jsonDecode(authResponse);
      } catch (_) {}

      if (authResObj != null && authResObj["status"] != "ACCEPTED") {
        throw "Transfer Rejected by Receiver.";
      } else if (authResObj == null && authResponse != "ACCEPTED") {
        throw "Transfer Rejected by Receiver.";
      }

      Map<String, dynamic> offsets = authResObj?["offsets"] ?? {};

      // 4. ضخ البيانات (Streaming on the fly)
      int sentBytes = 0;
      DateTime lastUpdate = DateTime.now();
      int bytesSinceUpdate = 0;

      for (var f in fileList) {
        int offset = (offsets[f["path"]] ?? 0) as int;
        File fileToRead = File(f["absPath"]);
        final reader = fileToRead.openRead(offset);

        sentBytes += offset;

        try {
          await for (var chunk in reader) {
            try {
              socket.add(chunk);
            } on SocketException {
              throw "Network disconnected during transfer.";
            }
            sentBytes += chunk.length;
            bytesSinceUpdate += chunk.length;

            if (DateTime.now().difference(lastUpdate).inMilliseconds > 500) {
              double speed = (bytesSinceUpdate / 1024 / 1024) / 0.5;
              onUpdate(
                TransferModel(
                  speed: speed,
                  transferred: sentBytes / 1024 / 1024,
                  fileName: p.basename(f["path"]),
                  status: "Pumping Data...",
                ),
              );
              bytesSinceUpdate = 0;
              lastUpdate = DateTime.now();
            }
          }
        } finally {}
      }

      await socket.flush();
      await socket.close();
      stopwatch.stop();

      double finalMB = totalBytesToSend / 1024 / 1024;
      double avg = finalMB / (stopwatch.elapsedMilliseconds / 1000);

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
      if (_isSenderCancelled) {
        onUpdate(TransferModel(status: "Transfer Cancelled"));
      } else if (e is SocketException) {
        final msg = e.message.toLowerCase();
        final osError = e.osError?.errorCode;

        if (osError == 111 ||
            osError == 10061 ||
            msg.contains("connection refused")) {
          onUpdate(
            TransferModel(
              status:
                  "Connection refused. Did the receiver click 'Start Receiving'?",
            ),
          );
        } else if (osError == 113 ||
            osError == 112 ||
            osError == 10060 ||
            osError == 10065) {
          onUpdate(
            TransferModel(
              status:
                  "Device not found. Please double-check the IP address and ensure both devices are on the exact same Wi-Fi/Hotspot.",
            ),
          );
        } else if (osError == 101 ||
            osError == 10051 ||
            msg.contains("network is unreachable")) {
          onUpdate(
            TransferModel(
              status:
                  "No network connection. Please turn on Wi-Fi or connect to the Hotspot.",
            ),
          );
        } else if (osError == 104 ||
            osError == 10054 ||
            osError == 32 ||
            msg.contains("connection reset by peer")) {
          onUpdate(
            TransferModel(status: "Transfer cancelled by the other device."),
          );
        } else {
          onUpdate(
            TransferModel(
              status: "Network Error: Please ensure Wi-Fi is connected.",
            ),
          );
        }
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
      _activeSenderSocket = null;
      _isSenderCancelled = false;
    }
  }

  void cancelSending() {
    _isSenderCancelled = true;
    _activeSenderSocket?.destroy();
    _activeSenderSocket = null;
  }

  // --- RECEIVER (Mobile): The New Direct-Stream Protocol ---
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
          port,
          shared: true,
        );
      } on SocketException catch (e) {
        throw "Could not bind server. Are you connected to Wi-Fi? (${e.message})";
      }
      onUpdate(TransferModel(status: "Receiver Ready (Port: $port)"));

      await for (Socket client in _server!) {
        _activeReceiverClient = client;
        Stopwatch stopwatch = Stopwatch()..start();

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

          // 1. قراءة الهيدر (JSON)
          if (metadata == null) {
            int newlineIndex = chunk.indexOf(10); // \n
            if (newlineIndex != -1) {
              headerBuffer.addAll(chunk.sublist(0, newlineIndex));
              String jsonStr = utf8.decode(headerBuffer);
              metadata = jsonDecode(jsonStr);

              offset = newlineIndex + 1;

              // --- Authorization Step ---
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
                onUpdate(TransferModel(status: "Transfer Rejected"));
                return; // exit the loop for this client
              } else {
                try {
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
          } // safety check
          List<dynamic> files = metadata["files"];
          try {
            while (offset < chunk.length && currentFileIndex < files.length) {
              var fileMeta = files[currentFileIndex];
              int targetSize = fileMeta["size"];

              // فتح الملف الجديد إذا لم يكن مفتوحاً
              if (currentSink == null) {
                String savePath = p.join(saveDirectory, fileMeta["path"]);
                File f = File(savePath);
                f.parent.createSync(recursive: true); // إنشاء الفولدرات الفرعية

                int existingLen = f.existsSync() ? f.lengthSync() : 0;
                if (existingLen > targetSize) {
                  f.deleteSync();
                  existingLen = 0;
                }

                currentSink = f.openWrite(mode: FileMode.append);
                _activeReceiverSink = currentSink;
                bytesReadForCurrentFile = existingLen;
                if (received == 0) {
                  // Add offsets of current + all previously completely skipped files to received
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

              // كتابة البيانات بدقة البايت
              if (remainingInChunk <= bytesNeeded) {
                currentSink.add(chunk.sublist(offset));
                bytesReadForCurrentFile += remainingInChunk;
                received += remainingInChunk;
                bytesSinceUpdate += remainingInChunk;
                offset += remainingInChunk;
              } else {
                currentSink.add(chunk.sublist(offset, offset + bytesNeeded));
                bytesReadForCurrentFile += bytesNeeded;
                received += bytesNeeded;
                bytesSinceUpdate += bytesNeeded;
                offset += bytesNeeded;
              }

              // تحديث السرعة في الواجهة
              if (DateTime.now().difference(lastTime).inMilliseconds > 500) {
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

              // إغلاق الملف عند اكتمال حجمه
              if (bytesReadForCurrentFile == targetSize) {
                await currentSink.flush();
                await currentSink.close();
                currentSink = null;
                _activeReceiverSink = null;
                bytesReadForCurrentFile = 0;
                currentFileIndex++;
              }
            }
          } finally {
            if (currentSink != null && currentFileIndex >= files.length) {
              // Cleanup if loop finished
              await currentSink.flush();
              await currentSink.close();
              _activeReceiverSink = null;
            }
          }
        } // end await for chunk

        if (_isReceiverCancelled) {
          throw "Transfer Cancelled";
        }

        // Final cleanup for sinking if any streams left open abruptly
        if (currentSink != null) {
          await currentSink.flush();
          await currentSink.close();
          currentSink = null;
          _activeReceiverSink = null;
        }

        // Check for premature drop (sender destroyed socket)
        int totalExpectedBytes =
            metadata?["files"]?.fold(0, (sum, f) => sum + (f["size"] as int)) ??
            0;
        if (metadata != null && received < totalExpectedBytes) {
          throw "Connection dropped prematurely.";
        }

        stopwatch.stop();
        double finalMB = received / 1024 / 1024;

        onUpdate(
          TransferModel(
            status: "Transfer Complete!",
            transferred: finalMB,
            avgSpeed: (finalMB / (stopwatch.elapsedMilliseconds / 1000))
                .toStringAsFixed(2),
            totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(
              1,
            ),
            fileName: "All files saved.",
          ),
        );
        try {
          client.destroy();
        } catch (_) {}
        onDone();
      }
    } catch (e) {
      if (_isReceiverCancelled) {
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
      _activeReceiverClient = null;
      _activeReceiverSink = null;
      _isReceiverCancelled = false;
    }
  }

  void stopReceiving() {
    _isReceiverCancelled = true;
    _server?.close();
    _server = null;

    _activeReceiverSink?.close();
    _activeReceiverSink = null;

    _activeReceiverClient?.destroy();
    _activeReceiverClient = null;
  }
}
