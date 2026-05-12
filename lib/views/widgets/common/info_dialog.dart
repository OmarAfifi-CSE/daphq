import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';

class InfoDialog extends StatelessWidget {
  const InfoDialog({super.key});

  static void show(BuildContext context) {
    showDialog(context: context, builder: (context) => const InfoDialog());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.dialogBackground,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: const Row(
        children: [
          Icon(Icons.help_outline_rounded, color: Colors.white70),
          SizedBox(width: 12),
          Text(
            "Information",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Follow these steps for a smooth transfer:",
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _stepItem(
              Icons.wifi_rounded,
              "Connect",
              "Both devices to the same network.",
            ),
            _stepItem(
              Icons.devices_rounded,
              "Discover",
              "Nearby devices appear automatically.",
            ),
            _stepItem(
              Icons.send_rounded,
              "Transfer",
              "Select a device and pick your files.",
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                ),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    color: AppColors.primaryLight,
                    size: 20,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Tip: Use 5GHz Wi-Fi for 10x faster speeds.",
                      style: TextStyle(
                        color: AppColors.primaryLight,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Got it", style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }

  Widget _stepItem(IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primaryLight, size: 18),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  desc,
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
