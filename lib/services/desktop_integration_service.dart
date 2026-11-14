import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

// Removed FFI Mutex definitions as they suffer from Dart GetLastError bugs

class DesktopIntegrationService {
  static final StreamController<List<String>> _controller =
      StreamController<List<String>>.broadcast();
  static Stream<List<String>> get fileStream => _controller.stream;

  static StreamSubscription<FileSystemEvent>? _queueWatchSub;
  static Timer? _watcherRecoveryTimer;
  static bool _isProcessingQueue = false;
  static bool _rescanRequested = false;
  static bool _isDisposed = false;
  static final List<String> _pendingPaths = []; // Buffer for early files
  static RandomAccessFile? _lockFile;

  @visibleForTesting
  static Future<void> Function()? debugFocusWindowOverride;

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
      final base = 'args_${DateTime.now().microsecondsSinceEpoch}';
      final tmpFile = File(p.join(queuePath, '$base.tmp'));
      tmpFile.writeAsStringSync(jsonEncode(args), flush: true);
      tmpFile.renameSync(p.join(queuePath, '$base.json'));
    } catch (e) {
      debugPrint('DesktopIntegrationService: _writeArgsToQueue error: $e');
    }
  }

  static void _startQueueWatcher(String queuePath) {
    _isDisposed = false;
    _attachDirectoryWatcher(queuePath);
    // Drain anything written before the watcher attached (e.g. cold-start Shell Extension batch).
    unawaited(_drainQueue(queuePath));
  }

  static void _attachDirectoryWatcher(String queuePath) {
    if (_isDisposed) return;
    _watcherRecoveryTimer?.cancel();
    _watcherRecoveryTimer = null;
    _queueWatchSub?.cancel();
    _queueWatchSub = null;

    final dir = Directory(queuePath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    try {
      _queueWatchSub = dir
          .watch(
            events:
                FileSystemEvent.create |
                FileSystemEvent.move |
                FileSystemEvent.modify,
          )
          .listen(
            (FileSystemEvent event) {
              if (_isDisposed) return;
              final bool isRelevant = switch (event) {
                FileSystemMoveEvent(:final destination) =>
                  destination?.toLowerCase().endsWith('.json') ?? true,
                FileSystemCreateEvent() || FileSystemModifyEvent() =>
                  !event.path.toLowerCase().endsWith('.tmp'),
                _ => false,
              };
              if (isRelevant) {
                unawaited(_drainQueue(queuePath));
              }
            },
            onError: (Object error) {
              debugPrint('DesktopIntegrationService: queue watch error: $error');
              _scheduleWatcherRecovery(queuePath);
            },
            onDone: () {
              if (!_isDisposed) {
                _scheduleWatcherRecovery(queuePath);
              }
            },
            cancelOnError: true,
          );
    } catch (e) {
      debugPrint('DesktopIntegrationService: failed to attach queue watch: $e');
      _scheduleWatcherRecovery(queuePath);
    }
  }

  static void _scheduleWatcherRecovery(String queuePath) {
    if (_isDisposed) return;
    _queueWatchSub?.cancel();
    _queueWatchSub = null;
    _watcherRecoveryTimer?.cancel();
    _watcherRecoveryTimer = Timer(const Duration(seconds: 2), () {
      if (_isDisposed) return;
      _attachDirectoryWatcher(queuePath);
      unawaited(_drainQueue(queuePath));
    });
  }

  static Future<void> _drainQueue(String queuePath) async {
    if (_isDisposed) return;
    if (_isProcessingQueue) {
      _rescanRequested = true;
      return;
    }

    _isProcessingQueue = true;
    bool deliveredAny = false;
    try {
      // Flush any early buffered paths once the UI listener has subscribed.
      if (_pendingPaths.isNotEmpty && _controller.hasListener) {
        _controller.add(List.from(_pendingPaths));
        _pendingPaths.clear();
      }

      final dir = Directory(queuePath);
      do {
        _rescanRequested = false;
        if (!dir.existsSync()) break;

        final List<File> jsonFiles = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

        if (jsonFiles.isEmpty) continue;

        final List<String> allPaths = [];
        for (final file in jsonFiles) {
          try {
            final content = file.readAsStringSync();
            final decoded = jsonDecode(content);
            if (decoded is List) {
              allPaths.addAll(decoded.map((e) => e.toString()));
            }
            file.deleteSync();
          } catch (e) {
            debugPrint('DesktopIntegrationService: error reading arg file: $e');
            try {
              file.deleteSync();
            } catch (_) {}
          }
        }

        if (allPaths.isNotEmpty) {
          deliveredAny = true;
          if (_controller.hasListener) {
            _controller.add(allPaths);
          } else {
            _pendingPaths.addAll(allPaths); // Buffer if UI isn't ready
          }
        }
      } while (_rescanRequested && !_isDisposed);

      if (deliveredAny && !_isDisposed) {
        await (debugFocusWindowOverride?.call() ?? _focusAppWindow());
      }
    } finally {
      _isProcessingQueue = false;
    }

    // Re-drain if another batch landed while focusing the window.
    if (_rescanRequested && !_isDisposed) {
      unawaited(_drainQueue(queuePath));
    }
  }

  static Future<void> _focusAppWindow() async {
    try {
      final bool isMinimized = await windowManager.isMinimized();
      if (isMinimized) {
        await windowManager.restore();
      }

      // Bypass Windows Focus Stealing Prevention
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
      await Future.delayed(const Duration(milliseconds: 100)); // Ensure it registers
      await windowManager.setAlwaysOnTop(false);
    } catch (e) {
      debugPrint('DesktopIntegrationService: windowManager focus error: $e');
    }
  }

  static void addInitialArgs(List<String> args) {
    if (args.isEmpty) return;
    if (_controller.hasListener) {
      _controller.add(args);
    } else {
      _pendingPaths.addAll(args);
    }
  }

  static void flushPendingArgs() {
    if (_pendingPaths.isNotEmpty && _controller.hasListener) {
      _controller.add(List.from(_pendingPaths));
      _pendingPaths.clear();
    }
  }

  @visibleForTesting
  static void debugStartQueueWatcher(String queuePath) =>
      _startQueueWatcher(queuePath);

  @visibleForTesting
  static Future<void> debugDrainQueue(String queuePath) =>
      _drainQueue(queuePath);

  @visibleForTesting
  static void debugResetForTest() {
    dispose();
    _pendingPaths.clear();
    _isProcessingQueue = false;
    _rescanRequested = false;
    debugFocusWindowOverride = null;
  }

  // Creates a named Win32 Mutex so the Shell Extension DLL can detect the running instance.
  // The DLL uses OpenMutexW to check for this mutex before launching a new process.
  static void _createWin32Mutex() {
    Pointer<Utf16>? name;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final createMutex = kernel32
          .lookupFunction<
            IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
            int Function(Pointer<Void>, int, Pointer<Utf16>)
          >('CreateMutexW');
      // Changed 'Global\\' to 'Local\\' because standard users don't have SeCreateGlobalPrivilege.
      // Since explorer.exe and the app run in the same session, Local works perfectly.
      name = 'Local\\Daphq_Unique_Mutex_Lock'.toNativeUtf16();
      createMutex(nullptr, 1, name);
    } catch (e) {
      debugPrint('DesktopIntegrationService: _createWin32Mutex error: $e');
    } finally {
      // Plan T-014: the native string must be freed on every path (the
      // shrinkeo twin of this file already does; this closes the drift).
      if (name != null) malloc.free(name);
    }
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
    } catch (e) {
      debugPrint('DesktopIntegrationService: _exitProcess failed: $e');
      exit(exitCode); // Fallback
    }
  }

  static void dispose() {
    _isDisposed = true;
    _watcherRecoveryTimer?.cancel();
    _watcherRecoveryTimer = null;
    _queueWatchSub?.cancel();
    _queueWatchSub = null;
  }
}
