import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';

class DirectTransferTipDialog extends StatefulWidget {
  final bool isDesktop;

  const DirectTransferTipDialog({super.key, this.isDesktop = false});

  static void show(BuildContext context, {bool isDesktop = false}) {
    showDialog(
      context: context,
      builder: (context) => DirectTransferTipDialog(isDesktop: isDesktop),
    );
  }

  @override
  State<DirectTransferTipDialog> createState() =>
      _DirectTransferTipDialogState();
}

class _DirectTransferTipDialogState extends State<DirectTransferTipDialog> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content = SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title Header with Glowing Icon
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: AppColors.primaryLight,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Lightning Speed Guide",
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // The Explanation Card (Why is it slow?)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(30),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withAlpha(6)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Why is the transfer speed slow?",
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  "When both devices are on the same Wi-Fi router, local wireless transfer is heavily throttled by the router's hardware driver limitations. Connecting via a direct hotspot completely bypasses the router for up to 10x faster speeds!",
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          const Text(
            "Choose one of these easy methods:",
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),

          // Option A: Windows Hotspot
          _buildOptionCard(
            context,
            title: "Method 1: Windows Hotspot",
            steps: [
              "Turn ON Mobile Hotspot in Windows settings.",
              "Connect your Mobile device to the Windows Wi-Fi network.",
              "Open the app on both devices and transfer at lightning speeds!",
            ],
            icon: Icons.computer_rounded,
          ),
          const SizedBox(height: 12),

          // Option B: Mobile Hotspot
          _buildOptionCard(
            context,
            title: "Method 2: Mobile Hotspot",
            steps: [
              "Turn ON Mobile Hotspot in your phone settings.",
              "Connect your Windows device to the Mobile Wi-Fi network.",
              "Open the app on both devices and start transferring immediately!",
            ],
            icon: Icons.phone_android_rounded,
          ),
          const SizedBox(height: 24),

          // Close button
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                backgroundColor: AppColors.primary.withAlpha(20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: AppColors.primary.withAlpha(40)),
                ),
              ),
              child: const Text(
                "Got It",
                style: TextStyle(
                  color: AppColors.primaryLight,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (widget.isDesktop) {
      content = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ScrollbarTheme(
          data: ScrollbarThemeData(
            thumbColor: WidgetStateProperty.all(Colors.white.withAlpha(60)),
            trackColor: WidgetStateProperty.all(Colors.transparent),
            trackBorderColor: WidgetStateProperty.all(Colors.transparent),
            thickness: WidgetStateProperty.all(6.0),
            radius: const Radius.circular(8),
            interactive: false,
          ),
          child: RawScrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            interactive: false,
            thickness: 6.0,
            radius: const Radius.circular(8),
            thumbColor: Colors.white.withAlpha(60),
            trackColor: Colors.transparent,
            trackBorderColor: Colors.transparent,
            child: content,
          ),
        ),
      );
    } else {
      content = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: content,
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 460),
            decoration: BoxDecoration(
              color: AppColors.dialogBackground.withAlpha(230),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withAlpha(12)),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withAlpha(12),
                  blurRadius: 40,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _buildOptionCard(
    BuildContext context, {
    required String title,
    required List<String> steps,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withAlpha(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.primaryLight, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 12),
          ...List.generate(steps.length, (index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.primaryLight,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      steps[index],
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
