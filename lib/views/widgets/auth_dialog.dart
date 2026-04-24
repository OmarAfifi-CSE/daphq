import 'package:flutter/material.dart';
import '../../core/app_colors.dart';

/// Shows a dialog asking the user to accept or reject an incoming transfer.
///
/// Returns `true` if accepted, `false` if rejected or dismissed.
Future<bool> showAuthDialog({
  required BuildContext context,
  required String senderIp,
  required int fileCount,
  required double totalSizeMB,
}) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(
            "Incoming Transfer",
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.dialogBackground,
          content: Text(
            "Sender: $senderIp\nFiles: $fileCount\nTotal Size: ${totalSizeMB.toStringAsFixed(2)} MB\n\nDo you want to accept?",
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text("Reject", style: TextStyle(color: Colors.redAccent)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text("Accept"),
            ),
          ],
        ),
      ) ??
      false;
}
