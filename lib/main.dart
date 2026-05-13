import 'dart:io';
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
    // Send message to main task to trigger clean stop in Cubit
    FlutterForegroundTask.sendDataToMain(id);
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
  
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  FlutterForegroundTask.initCommunicationPort();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: AppColors.background,
  ));

  if (Platform.isAndroid) {
    await requestAllPermissions();
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
}

Future<void> requestAllPermissions() async {
  if (Platform.isAndroid) {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 30) {
      // Android 11+ : Only need Manage External Storage + Notification
      await [Permission.notification].request();
      if (await Permission.manageExternalStorage.isDenied) {
        await Permission.manageExternalStorage.request();
      }
    } else {
      // Older Android: Need standard Storage + Notification
      await [Permission.storage, Permission.notification].request();
    }
  }
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
            return BlocProvider(
              create: (_) => TransferCubit(),
              child: MaterialApp(
                title: 'Daphq',
                debugShowCheckedModeBanner: false,
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
  @override
  void initState() {
    super.initState();
    SharingService.init(context);
  }

  @override
  void dispose() {
    SharingService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
