import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:window_manager/window_manager.dart';
import 'package:path/path.dart' as p;
import 'dart:ffi';
import 'package:ffi/ffi.dart';

// Removed FFI Mutex definitions as they suffer from Dart GetLastError bugs

class DesktopIntegrationService {
  static final StreamController<List<String>> _controller =
      StreamController<List<String>>.broadcast();
  static Stream<List<String>> get fileStream => _controller.stream;
  static Timer? _queueTimer;
  static final List<String> _pendingPaths = []; // Buffer for early files
  static RandomAccessFile? _lockFile;

  static Future<bool> handleSingleInstance(List<String> args) async {
    if (!Platform.isWindows) return true;

    final String tempDir =
        Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    final String lockFilePath = p.join(tempDir, 'daphq_single_instance.lock');
    final String queuePath = p.join(tempDir, 'daphq_queue');

    try {
      // 1. Attempt to lock a file exclusively. This is 100% OS-level atomic.
      final file = File(lockFilePath);
      if (!file.existsSync()) {
        file.createSync(recursive: true);
      }
      _lockFile = file.openSync(mode: FileMode.append);
      _lockFile!.lockSync(FileLock.exclusive); // Throws if another instance holds the lock

      // If we reach here, we successfully locked the file. We are PRIMARY.
      // Also create the Win32 Mutex so the Shell Extension DLL can detect us via OpenMutexW.
      _createWin32Mutex();
      _startQueueWatcher(queuePath);
      return true;

    } catch (e) {
      // Exception thrown -> lock is held by another instance -> We are SECONDARY.
      if (args.isNotEmpty) {
        _writeArgsToQueue(queuePath, args);
      }

      // Use standard Dart exit. Calling native ExitProcess via FFI can deadlock the Dart VM.
      exit(0);
    }
  }

  static void _writeArgsToQueue(String queuePath, List<String> args) {
    try {
      final dir = Directory(queuePath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final fileName = 'args_${DateTime.now().microsecondsSinceEpoch}.json';
      File(p.join(queuePath, fileName)).writeAsStringSync(jsonEncode(args));
    } catch (_) {}
  }

  static void _startQueueWatcher(String queuePath) {
    final dir = Directory(queuePath);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    _queueTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      // Dump buffered paths once UI is listening
      if (_pendingPaths.isNotEmpty && _controller.hasListener) {
        _controller.add(List.from(_pendingPaths));
        _pendingPaths.clear();
      }

      if (!dir.existsSync()) return;

      final List<FileSystemEntity> files = dir.listSync();
      if (files.isEmpty) return;

      final List<String> allPaths = [];
      for (var file in files) {
        if (file is File && file.path.endsWith('.json')) {
          try {
            final content = file.readAsStringSync();
            allPaths.addAll(List<String>.from(jsonDecode(content)));
            file.deleteSync();
          } catch (_) {}
        }
      }

      if (allPaths.isNotEmpty) {
        if (_controller.hasListener) {
          _controller.add(allPaths);
        } else {
          _pendingPaths.addAll(allPaths); // Buffer if UI isn't ready
        }
        windowManager.show();
        windowManager.focus();
      }
    });
  }

  static void addInitialArgs(List<String> args) {
    if (args.isNotEmpty) {
      _controller.add(args);
    }
  }

  // Creates a named Win32 Mutex so the Shell Extension DLL can detect the running instance.
  // The DLL uses OpenMutexW to check for this mutex before launching a new process.
  static void _createWin32Mutex() {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final createMutex = kernel32.lookupFunction<
          IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
          int Function(Pointer<Void>, int, Pointer<Utf16>)>('CreateMutexW');
      final name = 'Global\\Daphq_Unique_Mutex_Lock'.toNativeUtf16();
      createMutex(nullptr, 1, name);
      // Intentionally not freeing name or closing handle — held for process lifetime.
    } catch (_) {}
  }

  static void dispose() {
    _queueTimer?.cancel();
  }
}
