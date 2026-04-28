import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'views/home_page.dart';
import 'cubits/transfer_cubit.dart';
import 'core/app_constants.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('MyTaskHandler.onStart reached at $timestamp');
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isForceDestroy) async {
    print('MyTaskHandler.onDestroy reached! Force: $isForceDestroy');
  }

  @override
  void onNotificationButtonPressed(String id) {
    print('MyTaskHandler.onNotificationButtonPressed: $id');
    if (id == 'stopButton') {
      FlutterForegroundTask.sendDataToMain('STOP');
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp("/");
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();

  if (Platform.isAndroid) {
    await requestAllPermissions();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'transfer_channel',
        channelName: 'Transfer Service',
        channelDescription: 'Keeps background transfers alive.',
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
}

Future<void> requestAllPermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.storage,
    Permission.requestInstallPackages, // Required for sending APK files
    Permission.notification,
  ].request();

  // Full file access (required for Android 11+)
  if (await Permission.manageExternalStorage.isDenied) {
    await Permission.manageExternalStorage.request();
  }

  statuses.forEach((permission, status) {
    print('${permission.toString()}: $status');
  });
}

class DaphqApp extends StatelessWidget {
  const DaphqApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Size baseSize;
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          // Fixed design size for desktop to avoid weird stretching
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
            return MaterialApp(
              title: 'Daphq',
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                primarySwatch: Colors.indigo,
                useMaterial3: true,
                visualDensity: VisualDensity.adaptivePlatformDensity,
                fontFamily: 'Roboto',
              ),
              home: BlocProvider(
                create: (_) => TransferCubit(),
                child: const HomePage(),
              ),
            );
          },
        );
      },
    );
  }
}
