import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'views/home_page.dart';
import 'cubits/transfer_cubit.dart';

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
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp("/");
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      ),
    );
  }

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    WindowOptions windowOptions = WindowOptions(
      size: Size(800, 700),
      minimumSize: Size(450, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      title: 'Turbo Transfer Pro',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(TurboTransferApp());
}

Future<void> requestAllPermissions() async {
  // صلاحيات التخزين التقليدية
  Map<Permission, PermissionStatus> statuses = await [
    Permission.storage,
    Permission.requestInstallPackages, // لو هتبعت ملفات APK
    Permission.notification, // To create foreground service notification
  ].request();

  // طلب صلاحية الوصول الكامل للملفات (مهمة لأندرويد 11 وما فوق)
  if (await Permission.manageExternalStorage.isDenied) {
    await Permission.manageExternalStorage.request();
  }

  // التأكد من حالة الصلاحيات في الكونسول
  statuses.forEach((permission, status) {
    print('${permission.toString()}: $status');
  });
}

class TurboTransferApp extends StatelessWidget {
  const TurboTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Size baseSize;
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          // Fixed design size for desktop to avoid weird stretching
          baseSize = const Size(800, 700);
        } else {
          baseSize = const Size(360, 690);
        }

        return ScreenUtilInit(
          designSize: baseSize,
          minTextAdapt: true,
          splitScreenMode: true,
          builder: (context, child) {
            return MaterialApp(
              title: 'Turbo Transfer Pro',
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                primarySwatch: Colors.indigo,
                useMaterial3: true,
                visualDensity: VisualDensity.adaptivePlatformDensity,
                fontFamily: 'Roboto',
              ),
              home: BlocProvider(
                create: (_) => TransferCubit(),
                child: HomePage(),
              ),
            );
          },
        );
      },
    );
  }
}
