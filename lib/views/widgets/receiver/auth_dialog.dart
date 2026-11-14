import 'dart:ui';
import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';

/// Creates a non-dismissible dialog route for authorizing an incoming transfer.
DialogRoute<bool> createAuthDialogRoute({
  required BuildContext context,
  required String senderIp,
  required String senderName,
  required int fileCount,
  required String formattedSize,
  String? sasCode,
  bool isTls = false,
  bool isFingerprintMismatch = false,
  bool canTrustPeer = false,
  ValueChanged<bool>? onTrustChanged,
}) {
  return DialogRoute<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    builder: (context) => _AuthDialogContent(
      senderIp: senderIp,
      senderName: senderName,
      fileCount: fileCount,
      formattedSize: formattedSize,
      sasCode: sasCode,
      isTls: isTls,
      isFingerprintMismatch: isFingerprintMismatch,
      canTrustPeer: canTrustPeer,
      onTrustChanged: onTrustChanged,
    ),
  );
}

/// Shows a premium dialog asking the user to accept or reject an incoming transfer.
///
/// Returns `true` if accepted, `false` if rejected or dismissed.
Future<bool> showAuthDialog({
  required BuildContext context,
  required String senderIp,
  required String senderName,
  required int fileCount,
  required String formattedSize,
  String? sasCode,
  bool isTls = false,
  bool isFingerprintMismatch = false,
  bool canTrustPeer = false,
  ValueChanged<bool>? onTrustChanged,
}) async {
  return await Navigator.of(context, rootNavigator: true).push<bool>(
        createAuthDialogRoute(
          context: context,
          senderIp: senderIp,
          senderName: senderName,
          fileCount: fileCount,
          formattedSize: formattedSize,
          sasCode: sasCode,
          isTls: isTls,
          isFingerprintMismatch: isFingerprintMismatch,
          canTrustPeer: canTrustPeer,
          onTrustChanged: onTrustChanged,
        ),
      ) ??
      false;
}

class _AuthDialogContent extends StatefulWidget {
  final String senderIp;
  final String senderName;
  final int fileCount;
  final String formattedSize;
  final String? sasCode;
  final bool isTls;
  final bool isFingerprintMismatch;
  final bool canTrustPeer;
  final ValueChanged<bool>? onTrustChanged;

  const _AuthDialogContent({
    required this.senderIp,
    required this.senderName,
    required this.fileCount,
    required this.formattedSize,
    this.sasCode,
    this.isTls = false,
    this.isFingerprintMismatch = false,
    this.canTrustPeer = false,
    this.onTrustChanged,
  });

  @override
  State<_AuthDialogContent> createState() => _AuthDialogContentState();
}

class _AuthDialogContentState extends State<_AuthDialogContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  bool _trustDevice = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= 500;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 30, vertical: 60),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            constraints: BoxConstraints(
              minWidth: isWide ? 360 : 0,
              maxWidth: 400,
            ),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.dialogBackground.withAlpha(230),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withAlpha(12)),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withAlpha(15),
                  blurRadius: 40,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: isWide ? 332 : 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  // Animated incoming arrow icon
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: (widget.isFingerprintMismatch
                                  ? AppColors.danger
                                  : AppColors.primary)
                              .withAlpha(18),
                          boxShadow: [
                            BoxShadow(
                              color: (widget.isFingerprintMismatch
                                      ? AppColors.danger
                                      : AppColors.primary)
                                  .withAlpha(
                                    (20 + _pulseController.value * 30).toInt(),
                                  ),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          widget.isFingerprintMismatch
                              ? Icons.gpp_maybe_rounded
                              : Icons.arrow_downward_rounded,
                          color: widget.isFingerprintMismatch
                              ? AppColors.danger
                              : AppColors.primaryLight,
                          size: 28,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "Incoming Transfer",
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (widget.isTls) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.success.withAlpha(24),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color: AppColors.success.withAlpha(80),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock_rounded,
                            color: AppColors.success,
                            size: 13,
                          ),
                          SizedBox(width: 5),
                          Text(
                            "TLS 1.3 Encrypted",
                            style: TextStyle(
                              color: AppColors.success,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (widget.isFingerprintMismatch) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withAlpha(25),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.danger.withAlpha(110),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: AppColors.danger,
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "Security Warning: Device key changed since last trusted session. Verify PIN before accepting.",
                              style: TextStyle(
                                color: AppColors.dangerLight,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (widget.sasCode != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(22),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.primaryLight.withAlpha(70),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.pin_rounded,
                            color: AppColors.primaryLight,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          const Flexible(
                            child: Text(
                              "Verify PIN: ",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Flexible(
                            child: Text(
                              widget.sasCode!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 3.0,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),

                  // Sender info chips
                  _InfoChip(
                    icon: Icons.person_rounded,
                    label: "From",
                    value: widget.senderName,
                  ),
                  const SizedBox(height: 8),
                  _InfoChip(
                    icon: Icons.lan_rounded,
                    label: "IP",
                    value: widget.senderIp,
                  ),
                  const SizedBox(height: 8),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final bool isMobile = constraints.maxWidth < 310;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (isMobile) ...[
                            _InfoChip(
                              icon: Icons.file_copy_rounded,
                              label: "Files",
                              value: "${widget.fileCount}",
                            ),
                            const SizedBox(height: 8),
                            _InfoChip(
                              icon: Icons.data_usage_rounded,
                              label: "Size",
                              value: widget.formattedSize,
                            ),
                          ] else ...[
                            Row(
                              children: [
                                Expanded(
                                  child: _InfoChip(
                                    icon: Icons.file_copy_rounded,
                                    label: "Files",
                                    value: "${widget.fileCount}",
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _InfoChip(
                                    icon: Icons.data_usage_rounded,
                                    label: "Size",
                                    value: widget.formattedSize,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (widget.canTrustPeer &&
                              !widget.isFingerprintMismatch) ...[
                            const SizedBox(height: 12),
                            InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () {
                                setState(() => _trustDevice = !_trustDevice);
                                widget.onTrustChanged?.call(_trustDevice);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withAlpha(6),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.white.withAlpha(10),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Checkbox(
                                      value: _trustDevice,
                                      activeColor: AppColors.success,
                                      checkColor: Colors.black87,
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      onChanged: (val) {
                                        final next = val ?? false;
                                        setState(() => _trustDevice = next);
                                        widget.onTrustChanged?.call(next);
                                      },
                                    ),
                                    const Expanded(
                                      child: Text(
                                        "Trust this device for future auto-accept",
                                        style: TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),

                          // Action buttons
                          if (isMobile) ...[
                            _ActionButton(
                              label: "Accept",
                              icon: Icons.check_rounded,
                              colors: const [
                                AppColors.success,
                                AppColors.successLight,
                              ],
                              textColor: Colors.black87,
                              onTap: () => Navigator.pop(context, true),
                            ),
                            const SizedBox(height: 10),
                            _ActionButton(
                              label: "Reject",
                              icon: Icons.close_rounded,
                              colors: [
                                AppColors.danger.withAlpha(40),
                                AppColors.danger.withAlpha(20),
                              ],
                              textColor: AppColors.danger,
                              onTap: () => Navigator.pop(context, false),
                            ),
                          ] else ...[
                            Row(
                              children: [
                                Expanded(
                                  child: _ActionButton(
                                    label: "Reject",
                                    icon: Icons.close_rounded,
                                    colors: [
                                      AppColors.danger.withAlpha(40),
                                      AppColors.danger.withAlpha(20),
                                    ],
                                    textColor: AppColors.danger,
                                    onTap: () => Navigator.pop(context, false),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: _ActionButton(
                                    label: "Accept",
                                    icon: Icons.check_rounded,
                                    colors: const [
                                      AppColors.success,
                                      AppColors.successLight,
                                    ],
                                    textColor: Colors.black87,
                                    onTap: () => Navigator.pop(context, true),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(8)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primaryLight, size: 16),
          const SizedBox(width: 8),
          Flexible(
            flex: 0,
            child: Text(
              "$label: ",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final List<Color> colors;
  final Color textColor;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.colors,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: textColor, size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
