import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'views/home_page.dart';
import 'cubits/transfer_cubit.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    await requestAllPermissions();
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
    return MaterialApp(
      title: 'Turbo Transfer Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true, // استخدام التصميم الجديد Material 3
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Roboto', // تأكد من وجود الخط أو استخدم الخط الافتراضي
      ),
      home: BlocProvider(
        create: (_) => TransferCubit(),
        child: HomePage(),
      ),
    );
  }
}
