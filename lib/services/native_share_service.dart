import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../cubits/transfer_cubit.dart';
import 'package:flutter/material.dart';

class NativeShareService {
  static const EventChannel _stream = EventChannel(
    'com.omarafifi.daphq/share_stream',
  );
  static const MethodChannel _channel = MethodChannel(
    'com.omarafifi.daphq/share_manager',
  );

  static final List<String> _buffer = [];
  static bool _isFlushing = false;

  static void init(BuildContext context) {
    final cubit = context.read<TransferCubit>();

    _stream.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is String) {
          if (event.startsWith('{') && event.contains('"status"')) {
            try {
              final json = jsonDecode(event);
              if (json['status'] == 'done') {
                debugPrint('NativeShareService: All files processed.');
                _flushBuffer(cubit);
              } else if (json['status'] == 'error') {
                // Plan T-015: the native layer could not copy this file.
                final name = json['name']?.toString() ?? 'file';
                cubit.reportShareCopyError(name);
              }
            } catch (e) {
              debugPrint('NativeShareService JSON Error: $e');
            }
          } else {
            // It's a file path
            _buffer.add(event);
            if (!_isFlushing) {
              _scheduleFlush(cubit);
            }
          }
        }
      },
      onError: (dynamic error) {
        debugPrint('NativeShareService Error: $error');
      },
    );
  }

  static void _scheduleFlush(TransferCubit cubit) {
    _isFlushing = true;
    Future.delayed(const Duration(milliseconds: 200), () {
      _flushBuffer(cubit);
      _isFlushing = false;
    });
  }

  static void _flushBuffer(TransferCubit cubit) {
    if (_buffer.isNotEmpty) {
      final pathsToProcess = List<String>.from(_buffer);
      _buffer.clear();
      cubit.addSelectedPaths(pathsToProcess, showLoading: false);
    }
  }

  static Future<void> cancel() async {
    try {
      _buffer.clear();
      await _channel.invokeMethod('cancelShare');
      debugPrint('NativeShareService: Cancelled ongoing share operation.');
    } catch (e) {
      debugPrint('NativeShareService Cancel Error: $e');
    }
  }
}
