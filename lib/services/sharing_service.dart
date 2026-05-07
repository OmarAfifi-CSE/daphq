import 'package:share_handler/share_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../cubits/transfer_cubit.dart';

class SharingService {
  static void init(BuildContext context) async {
    final cubit = context.read<TransferCubit>();
    final handler = ShareHandlerPlatform.instance;
    
    // Get initial media if app was closed
    final initialMedia = await handler.getInitialSharedMedia();
    if (initialMedia != null && initialMedia.attachments != null) {
      _processAttachments(initialMedia.attachments!, cubit);
    }

    // Listen for sharing while app is running
    handler.sharedMediaStream.listen((SharedMedia media) {
      if (media.attachments != null) {
        _processAttachments(media.attachments!, cubit);
      }
    });
  }

  static void _processAttachments(List<SharedAttachment?> attachments, TransferCubit cubit) {
    final paths = attachments
        .where((a) => a != null)
        .map((a) => a!.path)
        .whereType<String>()
        .toList();
    
    if (paths.isNotEmpty) {
      cubit.addSelectedPaths(paths);
    }
  }

  static void dispose() {
    // share_handler handles its own cleanup
  }
}
