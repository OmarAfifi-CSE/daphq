import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import 'native_share_service.dart';

class SharingService {
  static const MethodChannel _channel = MethodChannel(
    'com.omarafifi.daphq/share_manager',
  );

  static void init(BuildContext context) async {
    if (!Platform.isAndroid) return; // iOS not supported yet in custom native

    // Initialize the streaming listener
    NativeShareService.init(context);

    // Ask native if we were launched from a share intent
    try {
      final bool wasLaunchedFromShare =
          await _channel.invokeMethod('wasLaunchedFromShare') ?? false;
      if (!wasLaunchedFromShare) {
        // Safe to clean cache! App was not launched via Share Intent
        clearAppCache();
        await _channel.invokeMethod('cleanShareCache');
      }
    } catch (e) {
      debugPrint('Failed to check share launch status: $e');
      clearAppCache();
      try {
        await _channel.invokeMethod('cleanShareCache');
      } catch (_) {}
    }
  }

  static void dispose() {
    NativeShareService.dispose();
  }
}
