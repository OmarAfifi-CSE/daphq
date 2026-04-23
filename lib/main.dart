import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:window_manager/window_manager.dart';
import 'views/home_page.dart';
import 'cubits/transfer_cubit.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    await requestAllPermissions();
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
  @override
  Widget build(BuildContext context) {
    // استخدم LayoutBuilder عشان نحدد الـ designSize بناءً على حجم الشاشة
    return LayoutBuilder(
      builder: (context, constraints) {
        // لو الشاشة عريضة (كمبيوتر/لابتوب)، خلي الـ designSize بنفس حجم الشاشة عشان ميكبرش العناصر
        Size baseSize = constraints.maxWidth > 600
            ? Size(constraints.maxWidth, constraints.maxHeight)
            : const Size(360, 690);

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
