import 'dart:io';
import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'views/home_page.dart';
import 'cubits/transfer_cubit.dart';
import 'core/app_constants.dart';
import 'core/app_colors.dart';
import 'services/sharing_service.dart';
import 'services/desktop_integration_service.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isForceDestroy) async {}

  @override
  void onNotificationButtonPressed(String id) {
    FlutterForegroundTask.sendDataToMain(id);
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp("/");
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
}

Future<void> clearAppCache() async {
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      // Clear file_picker's cache
      await FilePicker.clearTemporaryFiles();

      // Clear other temporary files (like those from share_handler)
      final tempDir = await getTemporaryDirectory();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
        await tempDir.create();
      }
      debugPrint('App cache cleared successfully!');
    } catch (e) {
      debugPrint('Failed to clear app cache: $e');
    }
  }
}

void main(List<String> args) async {
  // Check for single instance immediately on Windows
  if (Platform.isWindows) {
    bool isPrimary = await DesktopIntegrationService.handleSingleInstance(args);
    if (!isPrimary) return; // Kill the process before it loads anything
  }

  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(systemNavigationBarColor: AppColors.background),
  );

  if (Platform.isAndroid) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: AppConstants.notificationChannelId,
        channelName: AppConstants.notificationChannelName,
        channelDescription: AppConstants.notificationChannelDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.once(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
        stopWithTask: false,
      ),
    );
  }

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = const WindowOptions(
      size: Size(AppConstants.windowWidth, AppConstants.windowHeight),
      minimumSize: Size(
        AppConstants.windowMinWidth,
        AppConstants.windowMinHeight,
      ),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'Daphq',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const DaphqApp());

  // Add initial args if any
  if (args.isNotEmpty && Platform.isWindows) {
    Future.delayed(const Duration(milliseconds: 500), () {
      DesktopIntegrationService.addInitialArgs(args);
    });
  }
}

/// Coordinates Android startup permissions after the first Flutter frame so
/// `runApp()` never blocks on splash screens and Android 16's All-Files Settings
/// transition doesn't stall follow-up runtime Nearby/Bluetooth prompts.
class StartupPermissionCoordinator {
  StartupPermissionCoordinator._();

  static Completer<void>? _activeRun;
  static bool _completedOnce = false;

  static Future<void> waitUntilFinished() async {
    final active = _activeRun;
    if (active != null && !active.isCompleted) {
      await active.future;
    }
  }

  static Future<void> requestOnceAfterFirstFrame() async {
    if (!Platform.isAndroid) return;
    if (_completedOnce) return;
    if (_activeRun != null && !_activeRun!.isCompleted) {
      await _activeRun!.future;
      return;
    }
    final completer = Completer<void>();
    _activeRun = completer;
    try {
      await requestAllPermissions();
      _completedOnce = true;
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_activeRun, completer)) {
        _activeRun = null;
      }
    }
  }
}

Future<void> requestAllPermissions() async {
  if (!Platform.isAndroid) return;
  try {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    // Ask fast in-app runtime dialogs BEFORE launching All-Files Settings.
    // On Android 11-16, granting MANAGE_EXTERNAL_STORAGE can trigger a storage
    // FUSE remount or background process restart; completing Nearby/Notifications
    // beforehand prevents a multi-second blank pause when returning from Settings.
    if (sdkInt >= 33) {
      if (await Permission.notification.isDenied) {
        await [Permission.notification].request();
      }
      final nearbyGroup = <Permission>[
        Permission.nearbyWifiDevices,
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ];
      final toRequest = <Permission>[];
      for (final perm in nearbyGroup) {
        if (!await perm.isGranted) {
          toRequest.add(perm);
        }
      }
      if (toRequest.isNotEmpty) {
        await toRequest.request();
      }
    } else if (sdkInt >= 31) {
      if (await Permission.notification.isDenied) {
        await [Permission.notification].request();
      }
      await [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
    } else {
      await [
        Permission.storage,
        Permission.notification,
        Permission.locationWhenInUse,
      ].request();
    }

    if (sdkInt >= 30 && await Permission.manageExternalStorage.isDenied) {
      await Permission.manageExternalStorage.request();
    }
  } catch (_) {}
}

class DaphqApp extends StatelessWidget {
  const DaphqApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Size baseSize;
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          baseSize = const Size(
            AppConstants.windowWidth,
            AppConstants.windowHeight,
          );
        } else {
          baseSize = const Size(360, 690);
        }

        return ScreenUtilInit(
          designSize: baseSize,
          minTextAdapt: true,
          splitScreenMode: true,
          builder: (context, child) {
            return BlocProvider(
              create: (_) => TransferCubit(),
              child: MaterialApp(
                title: 'Daphq',
                debugShowCheckedModeBanner: false,
                scrollBehavior: const MaterialScrollBehavior().copyWith(
                  dragDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.unknown,
                  },
                ),
                theme: ThemeData(
                  brightness: Brightness.dark,
                  scaffoldBackgroundColor: AppColors.background,
                  primaryColor: AppColors.primary,
                  colorScheme: const ColorScheme.dark(
                    primary: AppColors.primary,
                    surface: AppColors.appBarBackground,
                  ),
                  textSelectionTheme: TextSelectionThemeData(
                    cursorColor: AppColors.primary,
                    selectionColor: AppColors.primary.withAlpha(100),
                    selectionHandleColor: AppColors.primary,
                  ),
                  splashFactory: InkSparkle.splashFactory,
                  useMaterial3: true,
                  visualDensity: VisualDensity.adaptivePlatformDensity,
                  fontFamily: 'Roboto',
                ),
                home: const _AppInit(child: HomePage()),
              ),
            );
          },
        );
      },
    );
  }
}

class _AppInit extends StatefulWidget {
  final Widget child;
  const _AppInit({required this.child});

  @override
  State<_AppInit> createState() => _AppInitState();
}

class _AppInitState extends State<_AppInit> {
  StreamSubscription? _externalFilesSubscription;

  @override
  void initState() {
    super.initState();
    SharingService.init(context);

    _externalFilesSubscription = DesktopIntegrationService.fileStream.listen((
      paths,
    ) {
      if (mounted) {
        context.read<TransferCubit>().addExternalFiles(paths);
      }
    });
    DesktopIntegrationService.flushPendingArgs();
  }

  @override
  void dispose() {
    _externalFilesSubscription?.cancel();
    if (Platform.isAndroid) {
      SharingService.dispose();
    }
    if (Platform.isWindows) {
      DesktopIntegrationService.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
