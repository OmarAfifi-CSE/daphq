import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';

/// Shows a dialog asking the user to accept or reject an incoming transfer.
///
/// Returns `true` if accepted, `false` if rejected or dismissed.
Future<bool> showAuthDialog({
  required BuildContext context,
  required String senderIp,
  required String senderName,
  required int fileCount,
  required String formattedSize,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text(
            "Incoming Transfer",
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.dialogBackground,
          content: Text(
            "From: $senderName\nIP: $senderIp\nFiles: $fileCount\nTotal Size: $formattedSize\n\nDo you want to accept?",
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                "Reject",
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Accept"),
            ),
          ],
        ),
      ) ??
      false;
}
