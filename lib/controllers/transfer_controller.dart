import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'package:path/path.dart' as p;
import '../models/transfer_model.dart';
import 'package:flutter/foundation.dart'; // import to detect platform

class TransferController {
  static const int port = 9999;
  ServerSocket? _server;

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
          String normalizedPath = p.relative(f.path, from: p.dirname(path)).replaceAll(r'\', '/');
          fileList.add({"path": normalizedPath, "size": size, "absPath": f.path});
          totalBytesToSend += size;
        }
      } else {
        var f = File(path);
        if (!f.existsSync()) throw "File not found!";
        int size = f.lengthSync();
        fileList.add({"path": p.basename(path), "size": size, "absPath": f.path});
        totalBytesToSend += size;
      }

      if (totalBytesToSend == 0) throw "Error: The selected item is empty (0.0 MB).";

      // 2. الاتصال بالموبايل
      onUpdate(TransferModel(status: "Connecting..."));
      final socket = await Socket.connect(targetIp, port, timeout: Duration(seconds: 5));
      socket.setOption(SocketOption.tcpNoDelay, true);

      // 3. إرسال خريطة الملفات (JSON Header)
      Map<String, dynamic> metadata = {
        "files": fileList.map((e) => {"path": e["path"], "size": e["size"]}).toList()
      };

      String header = jsonEncode(metadata) + "\n";
      socket.write(header);
      await socket.flush();

      // 4. ضخ البيانات (Streaming on the fly)
      int sentBytes = 0;
      DateTime lastUpdate = DateTime.now();
      int bytesSinceUpdate = 0;

      for (var f in fileList) {
        File fileToRead = File(f["absPath"]);
        final reader = fileToRead.openRead();
        try {
          await for (var chunk in reader) {
            socket.add(chunk);
            sentBytes += chunk.length;
            bytesSinceUpdate += chunk.length;

            if (DateTime.now().difference(lastUpdate).inMilliseconds > 500) {
              double speed = (bytesSinceUpdate / 1024 / 1024) / 0.5;
              onUpdate(TransferModel(
                speed: speed,
                transferred: sentBytes / 1024 / 1024,
                fileName: p.basename(f["path"]),
                status: "Pumping Data...",
              ));
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

      onUpdate(TransferModel(
        status: "SUCCESSFULLY SENT!",
        transferred: finalMB,
        avgSpeed: avg.toStringAsFixed(2),
        totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1),
        fileName: isFolder ? p.basename(path) : fileList.first["path"],
      ));
      onDone();

    } catch (e) {
      onUpdate(TransferModel(status: "Error: $e"));
      onDone();
    }
  }

  // --- RECEIVER (Mobile): The New Direct-Stream Protocol ---
  Future<void> startReceiver({
    required String saveDirectory,
    required Function(TransferModel) onUpdate,
    required VoidCallback onDone,
  }) async {
    try {
      if (_server != null) await _server!.close();
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
      onUpdate(TransferModel(status: "Receiver Ready (Port: $port)"));

      await for (Socket client in _server!) {
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
            } else {
              headerBuffer.addAll(chunk);
              continue;
            }
          }

          // 2. معالجة وتوزيع الداتا الخام على الملفات
          List<dynamic> files = metadata!["files"];
          try {
            while (offset < chunk.length && currentFileIndex < files.length) {
              var fileMeta = files[currentFileIndex];
              int targetSize = fileMeta["size"];

              // فتح الملف الجديد إذا لم يكن مفتوحاً
              if (currentSink == null) {
                String savePath = p.join(saveDirectory, fileMeta["path"]);
                File f = File(savePath);
                f.parent.createSync(recursive: true); // إنشاء الفولدرات الفرعية
                currentSink = f.openWrite();
              }

              int remainingInChunk = chunk.length - offset;
              int bytesNeeded = targetSize - bytesReadForCurrentFile;

              // كتابة البيانات بدقة البايت
              if (remainingInChunk <= bytesNeeded) {
                currentSink!.add(chunk.sublist(offset));
                bytesReadForCurrentFile += remainingInChunk;
                received += remainingInChunk;
                bytesSinceUpdate += remainingInChunk;
                offset += remainingInChunk;
              } else {
                currentSink!.add(chunk.sublist(offset, offset + bytesNeeded));
                bytesReadForCurrentFile += bytesNeeded;
                received += bytesNeeded;
                bytesSinceUpdate += bytesNeeded;
                offset += bytesNeeded;
              }

              // تحديث السرعة في الواجهة
              if (DateTime.now().difference(lastTime).inMilliseconds > 500) {
                double speed = (bytesSinceUpdate / 1024 / 1024) / 0.5;
                onUpdate(TransferModel(
                  speed: speed,
                  transferred: received / 1024 / 1024,
                  fileName: p.basename(fileMeta["path"]),
                  status: "Receiving Data...",
                ));
                bytesSinceUpdate = 0;
                lastTime = DateTime.now();
              }

              // إغلاق الملف عند اكتمال حجمه
              if (bytesReadForCurrentFile == targetSize) {
                await currentSink!.flush();
                await currentSink!.close();
                currentSink = null;
                bytesReadForCurrentFile = 0;
                currentFileIndex++;
              }
            }
          } finally {
            if (currentSink != null && currentFileIndex >= files.length) { // Cleanup if loop finished
              await currentSink!.flush();
              await currentSink!.close();
            }
          }
        } // end await for chunk

        // Final cleanup for sinking if any streams left open abruptly
        if (currentSink != null) {
            await currentSink!.flush();
            await currentSink!.close();
            currentSink = null;
        }

        stopwatch.stop();
        double finalMB = received / 1024 / 1024;

        onUpdate(TransferModel(
          status: "Transfer Complete!",
          transferred: finalMB,
          avgSpeed: (finalMB / (stopwatch.elapsedMilliseconds / 1000)).toStringAsFixed(2),
          totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1),
          fileName: "All files saved.",
        ));
        client.destroy();
        onDone();
      }
    } catch (e) {
      onUpdate(TransferModel(status: "Error: $e"));
      onDone();
    }
  }

  void stopReceiver() {
    _server?.close();
    _server = null;
  }
}