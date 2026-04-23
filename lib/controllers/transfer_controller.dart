import 'dart:io';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import '../models/transfer_model.dart';

class TransferController {
  static const int port = 9999;
  ServerSocket? _server;

  // --- SENDER (PC) ---
  Future<void> sendData({
    required String path,
    required String targetIp,
    required String targetFolder,
    required bool isFolder,
    required Function(TransferModel) onUpdate,
  }) async {
    Stopwatch stopwatch = Stopwatch()..start();
    try {
      onUpdate(TransferModel(status: "Preparing Tar..."));

      // 1. إنشاء الـ Tar
      String tempTar = p.join(Directory.systemTemp.path, "out.tar");
      var encoder = TarFileEncoder();
      encoder.create(tempTar);
      if (isFolder) {
        encoder.addDirectory(Directory(path));
      } else {
        encoder.addFile(File(path));
      }
      encoder.close();

      File file = File(tempTar);
      String name = p.basename(path);

      // 2. الاتصال
      onUpdate(TransferModel(status: "Connecting..."));
      final socket = await Socket.connect(targetIp, port, timeout: Duration(seconds: 5));
      socket.setOption(SocketOption.tcpNoDelay, true);
      // تم إزالة سطر sendBuffer لأنه غير مدعوم في Dart والـ OS هيتكفل بيه

      // 3. إرسال الهيدر
      socket.write("$targetFolder\n");
      await socket.flush();

      // 4. ضخ البيانات
      int sentBytes = 0;
      DateTime lastUpdate = DateTime.now();
      int bytesSinceUpdate = 0;

      await for (var chunk in file.openRead()) {
        socket.add(chunk);
        sentBytes += chunk.length;
        bytesSinceUpdate += chunk.length;

        if (DateTime.now().difference(lastUpdate).inMilliseconds > 500) {
          double speed = (bytesSinceUpdate / 1024 / 1024) / 0.5;
          onUpdate(TransferModel(
            speed: speed,
            transferred: sentBytes / 1024 / 1024,
            fileName: name,
            status: "Pumping...",
          ));
          bytesSinceUpdate = 0;
          lastUpdate = DateTime.now();
        }
      }

      await socket.flush();
      await socket.close();
      stopwatch.stop();

      double finalMB = sentBytes / 1024 / 1024;
      double avg = finalMB / (stopwatch.elapsedMilliseconds / 1000);

      onUpdate(TransferModel(
        status: "SUCCESSFULLY SENT!",
        transferred: finalMB,
        avgSpeed: avg.toStringAsFixed(2),
        totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1),
        fileName: name,
      ));

      if (await file.exists()) await file.delete();

    } catch (e) {
      onUpdate(TransferModel(status: "Error: $e"));
    }
  }

  // --- RECEIVER (Mobile) ---
  Future<void> startReceiver({
    required String sdcardPath,
    required Function(TransferModel) onUpdate,
  }) async {
    try {
      if (_server != null) await _server!.close();
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
      onUpdate(TransferModel(status: "Turbo-Receiver Ready..."));

      await for (Socket client in _server!) {
        Stopwatch stopwatch = Stopwatch()..start();

        List<int> headerBuffer = [];
        bool headerRead = false;
        String targetFolder = "";
        String finalPath = "";

        File? tempFile;
        IOSink? sink;

        int received = 0;
        int bytesSinceUpdate = 0;
        DateTime lastTime = DateTime.now();

        await for (var chunk in client) {
          if (!headerRead) {
            // قراءة الهيدر بايت بايت عشان نفصل النص عن البيانات المضغوطة
            for (int i = 0; i < chunk.length; i++) {
              if (chunk[i] == 10) { // كود حرف \n
                targetFolder = utf8.decode(headerBuffer).trim();
                headerRead = true;

                if (targetFolder == "Downloads") {
                  finalPath = p.join(sdcardPath, "Download");
                } else {
                  finalPath = p.join(sdcardPath, targetFolder);
                }
                Directory(finalPath).createSync(recursive: true);

                tempFile = File(p.join(finalPath, "incoming.tar"));
                sink = tempFile.openWrite();

                var remaining = chunk.sublist(i + 1);
                if (remaining.isNotEmpty) {
                  sink.add(remaining);
                  received += remaining.length;
                  bytesSinceUpdate += remaining.length;
                }
                onUpdate(TransferModel(status: "Receiving...", fileName: "Streaming Data..."));
                break;
              } else {
                headerBuffer.add(chunk[i]);
              }
            }
          } else {
            sink!.add(chunk);
            received += chunk.length;
            bytesSinceUpdate += chunk.length;

            if (DateTime.now().difference(lastTime).inMilliseconds > 500) {
              double speed = (bytesSinceUpdate / 1024 / 1024) / 0.5;
              onUpdate(TransferModel(
                speed: speed,
                transferred: received / 1024 / 1024,
                fileName: "Extracting soon...",
                status: "Streaming...",
              ));
              bytesSinceUpdate = 0;
              lastTime = DateTime.now();
            }
          }
        }

        await sink?.close();

        // --- الفك الكلاسيكي المضمون ---
        if (tempFile != null && await tempFile.exists()) {
          onUpdate(TransferModel(status: "Extracting Files..."));

          final bytes = await tempFile.readAsBytes();
          final archive = TarDecoder().decodeBytes(bytes);

          for (var file in archive) {
            final outPath = p.join(finalPath, file.name);
            if (file.isFile) {
              File(outPath)..createSync(recursive: true)..writeAsBytesSync(file.content as List<int>);
            } else {
              Directory(outPath).createSync(recursive: true);
            }
          }

          await tempFile.delete();
        }

        stopwatch.stop();
        double finalMB = received / 1024 / 1024;

        onUpdate(TransferModel(
          status: "Success!",
          transferred: finalMB,
          avgSpeed: (finalMB / (stopwatch.elapsedMilliseconds / 1000)).toStringAsFixed(2),
          totalTime: (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1),
          fileName: "Done",
        ));
        client.destroy();
      }
    } catch (e) {
      onUpdate(TransferModel(status: "Error: $e"));
    }
  }
}