import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../security/trusted_devices_service.dart';

/// Displays pinned TLS peers so users can inspect fingerprints or revoke trust.
class TrustedDevicesDialog extends StatelessWidget {
  final bool isDesktop;

  const TrustedDevicesDialog({super.key, required this.isDesktop});

  static Future<void> show(
    BuildContext context, {
    required bool isDesktop,
  }) async {
    if (isDesktop) {
      return showDialog(
        context: context,
        builder: (_) => const TrustedDevicesDialog(isDesktop: true),
      );
    }
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const TrustedDevicesDialog(isDesktop: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double scale = isDesktop ? context.desktopScale : 1.0;

    final Widget content = ClipRRect(
      borderRadius: isDesktop
          ? BorderRadius.circular(20.rr(true, desktopScale: scale))
          : const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: isDesktop ? 440 : 500,
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          padding: EdgeInsets.all(20.rr(isDesktop, desktopScale: scale)),
          decoration: BoxDecoration(
            color: AppColors.dialogBackground.withAlpha(240),
            borderRadius: isDesktop
                ? BorderRadius.circular(20.rr(true, desktopScale: scale))
                : const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withAlpha(14)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8.rr(isDesktop, desktopScale: scale)),
                    decoration: BoxDecoration(
                      color: AppColors.success.withAlpha(22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.verified_user_rounded,
                      color: AppColors.success,
                      size: 20.rx(isDesktop, desktopScale: scale),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Trusted Devices",
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 17.rx(isDesktop, desktopScale: scale),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          "Auto-accept transfers verified via TLS 1.3 key pinning",
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 11.rx(isDesktop, desktopScale: scale),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: BlocSelector<TransferCubit, TransferState,
                    List<TrustedDevice>>(
                  selector: (state) => state.trustedDevices,
                  builder: (context, devices) {
                    if (devices.isEmpty) {
                      return SingleChildScrollView(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 28,
                            horizontal: 16,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(6),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withAlpha(10),
                            ),
                          ),
                          child: const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.shield_outlined,
                                color: AppColors.textMuted,
                                size: 32,
                              ),
                              SizedBox(height: 10),
                              Text(
                                "No trusted devices yet",
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Check "Trust this device" when receiving a transfer or scan a QR token to enable instant zero-prompt transfers.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }

                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: devices.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final device = devices[index];
                        final isWin =
                            device.platform.toLowerCase().contains('windows');
                        final shortFp = device.certFingerprint.length >= 12
                            ? '${device.certFingerprint.substring(0, 12).toUpperCase()}...'
                            : device.certFingerprint;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(8),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppColors.success.withAlpha(35),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isWin
                                    ? Icons.laptop_windows_rounded
                                    : Icons.phone_android_rounded,
                                color: AppColors.primaryLight,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      device.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Text(
                                      "Key: $shortFp",
                                      style: const TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: () => context
                                    .read<TransferCubit>()
                                    .revokeTrustedDevice(device.peerId),
                                child: const Text(
                                  "Revoke",
                                  style: TextStyle(
                                    color: AppColors.danger,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (isDesktop) {
      return Dialog(backgroundColor: Colors.transparent, child: content);
    }
    return content;
  }
}
