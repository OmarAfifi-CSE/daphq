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
      _lockFile!.lockSync(
        FileLock.exclusive,
      ); // Throws if another instance holds the lock

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

      // Use native ExitProcess via FFI to guarantee instantaneous termination without Dart VM deadlocks.
      _exitProcess(0);
      return false; // Satisfy Dart static analysis (never reached since process exits)
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

    _queueTimer = Timer.periodic(const Duration(milliseconds: 300), (
      timer,
    ) async {
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

        bool isMinimized = await windowManager.isMinimized();
        if (isMinimized) {
          await windowManager.restore();
        }
        
        // Bypass Windows Focus Stealing Prevention
        await windowManager.setAlwaysOnTop(true);
        await windowManager.show();
        await windowManager.focus();
        await Future.delayed(const Duration(milliseconds: 100)); // Ensure it registers
        await windowManager.setAlwaysOnTop(false);
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
      final createMutex = kernel32
          .lookupFunction<
            IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
            int Function(Pointer<Void>, int, Pointer<Utf16>)
          >('CreateMutexW');
      // Changed 'Global\\' to 'Local\\' because standard users don't have SeCreateGlobalPrivilege.
      // Since explorer.exe and the app run in the same session, Local works perfectly.
      final name = 'Local\\Daphq_Unique_Mutex_Lock'.toNativeUtf16();
      createMutex(nullptr, 1, name);
    } catch (_) {}
  }

  // Instantly terminates the process using Windows API to avoid Flutter/Dart VM shutdown hangs.
  static void _exitProcess(int exitCode) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final exitProcess = kernel32
          .lookupFunction<Void Function(Uint32), void Function(int)>(
            'ExitProcess',
          );
      exitProcess(exitCode);
    } catch (_) {
      exit(exitCode); // Fallback
    }
  }

  static void dispose() {
    _queueTimer?.cancel();
  }
}
