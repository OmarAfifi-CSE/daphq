import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';
import '../../../cubits/transfer_cubit.dart';
import 'animated_press_button.dart';
import 'custom_snackbar.dart';

/// Displays this device's encrypted `daphq://pair?...` QR code / token
/// and lets users paste a peer's token when Bluetooth/mDNS are unavailable.
class QrPairingDialog extends StatefulWidget {
  final bool isDesktop;

  const QrPairingDialog({super.key, required this.isDesktop});

  static Future<void> show(
    BuildContext context, {
    required bool isDesktop,
  }) async {
    if (isDesktop) {
      return showDialog(
        context: context,
        builder: (_) => const QrPairingDialog(isDesktop: true),
      );
    }
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const QrPairingDialog(isDesktop: false),
    );
  }

  @override
  State<QrPairingDialog> createState() => _QrPairingDialogState();
}

class _QrPairingDialogState extends State<QrPairingDialog> {
  final TextEditingController _tokenController = TextEditingController();
  Future<String?>? _pairingUriFuture;
  String? _inlineFeedback;
  bool _inlineError = false;
  bool _isPairing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pairingUriFuture ??=
        context.read<TransferCubit>().buildLocalPairingUri();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _copyToken(String uri) async {
    await Clipboard.setData(ClipboardData(text: uri));
    if (!mounted) return;
    CustomSnackBar.show(
      context,
      message: "Pairing token copied to clipboard.",
      backgroundColor: AppColors.success,
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) return;
    if (text != null && text.isNotEmpty) {
      setState(() {
        _tokenController.text = text;
        _inlineFeedback = null;
      });
    }
  }

  Future<void> _submitToken() async {
    final raw = _tokenController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _inlineError = true;
        _inlineFeedback = "Paste a valid daphq://pair token first.";
      });
      return;
    }

    setState(() {
      _isPairing = true;
      _inlineFeedback = null;
    });

    final cubit = context.read<TransferCubit>();
    try {
      final paired = await cubit.trustPeerFromQr(raw);
      if (!mounted) return;

      if (paired == null) {
        setState(() {
          _isPairing = false;
          _inlineError = true;
          _inlineFeedback = "Invalid pairing token format.";
        });
        return;
      }

      CustomSnackBar.show(
        context,
        message: "Paired & trusted ${paired.name}.",
        backgroundColor: AppColors.success,
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isPairing = false;
          _inlineError = true;
          _inlineFeedback = "Failed to save trusted device. Please retry.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;
    final double scale = isDesktop ? context.desktopScale : 1.0;

    final Widget body = ClipRRect(
      borderRadius: isDesktop
          ? BorderRadius.circular(20.rr(true, desktopScale: scale))
          : const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: isDesktop ? 440 : 500,
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          padding: EdgeInsets.all(20.rr(isDesktop, desktopScale: scale)),
          decoration: BoxDecoration(
            color: AppColors.dialogBackground.withAlpha(240),
            borderRadius: isDesktop
                ? BorderRadius.circular(20.rr(true, desktopScale: scale))
                : const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withAlpha(14)),
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8.rr(isDesktop, desktopScale: scale)),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(20),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.qr_code_2_rounded,
                        color: AppColors.primaryLight,
                        size: 20.rx(isDesktop, desktopScale: scale),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "QR & Instant Pairing",
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 17.rx(isDesktop, desktopScale: scale),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            "Zero-router fallback or instant device trust",
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
                const SizedBox(height: 16),
                FutureBuilder<String?>(
                  future: _pairingUriFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                          ),
                        ),
                      );
                    }
                    if (snapshot.hasError) {
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.danger.withAlpha(24),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.danger.withAlpha(90),
                          ),
                        ),
                        child: const Text(
                          "Could not generate pairing QR identity.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.danger),
                        ),
                      );
                    }
                    final uri = snapshot.data;
                    if (uri == null || uri.isEmpty) {
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          "Generating device TLS identity...",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: QrImageView(
                              data: uri,
                              version: QrVersions.auto,
                              size: 168,
                              backgroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: () => _copyToken(uri),
                          icon: const Icon(
                            Icons.copy_rounded,
                            size: 16,
                            color: AppColors.primaryLight,
                          ),
                          label: const Text(
                            "Copy My Pair Token",
                            style: TextStyle(
                              color: AppColors.primaryLight,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                Divider(color: Colors.white.withAlpha(12), height: 24),
                Text(
                  "Pair with another device token",
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13.rx(isDesktop, desktopScale: scale),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _tokenController,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12,
                  ),
                  decoration: InputDecoration(
                    hintText: "Paste daphq://pair?...",
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: Colors.black.withAlpha(45),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      tooltip: "Paste",
                      onPressed: _pasteFromClipboard,
                      icon: const Icon(
                        Icons.content_paste_rounded,
                        color: AppColors.primaryLight,
                        size: 18,
                      ),
                    ),
                  ),
                ),
                if (_inlineFeedback != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _inlineFeedback!,
                    style: TextStyle(
                      color:
                          _inlineError ? AppColors.danger : AppColors.success,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                AnimatedPressButton(
                  isDesktop: isDesktop,
                  onPressed: _isPairing ? null : _submitToken,
                  gradientColors: const [
                    AppColors.primary,
                    AppColors.primaryLight,
                  ],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.verified_user_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _isPairing ? "Pairing..." : "Pair & Trust Device",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (isDesktop) {
      return Dialog(backgroundColor: Colors.transparent, child: body);
    }
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: body,
    );
  }
}
