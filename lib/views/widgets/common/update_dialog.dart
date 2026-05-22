import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';

class UpdateDialog extends StatelessWidget {
  final String newVersion;
  final String whatsNew;
  final String downloadUrl;
  final bool isDesktop;

  const UpdateDialog({
    super.key,
    required this.newVersion,
    required this.whatsNew,
    required this.downloadUrl,
    required this.isDesktop,
  });

  Future<void> _launchUpdateUrl() async {
    final Uri url = Uri.parse(downloadUrl);
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20.rr(isDesktop)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 500 : double.infinity,
            ),
            padding: EdgeInsets.all(24.rw(isDesktop)),
            decoration: BoxDecoration(
              color: AppColors.dialogBackground.withAlpha(230),
              borderRadius: BorderRadius.circular(20.rr(isDesktop)),
              border: Border.all(color: Colors.white.withAlpha(12)),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withAlpha(10),
                  blurRadius: 40,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(10.rr(isDesktop)),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(15),
                        borderRadius: BorderRadius.circular(12.rr(isDesktop)),
                      ),
                      child: Icon(
                        Icons.system_update_alt,
                        color: AppColors.primaryLight,
                        size: 24.0.rx(isDesktop),
                      ),
                    ),
                    SizedBox(width: 14.0.rw(isDesktop)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Update Available',
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 18.0.rx(isDesktop),
                            ),
                          ),
                          SizedBox(height: 2.rh(isDesktop)),
                          Text(
                            'Version $newVersion is now available.',
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 13.0.rx(isDesktop),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 20.0.rh(isDesktop)),
                Text(
                  "What's New:",
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15.0.rx(isDesktop),
                  ),
                ),
                SizedBox(height: 10.0.rh(isDesktop)),
                Container(
                  width: double.infinity,
                  constraints: BoxConstraints(maxHeight: 200.rh(isDesktop)),
                  padding: EdgeInsets.all(14.0.rw(isDesktop)),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(6),
                    borderRadius: BorderRadius.circular(12.0.rr(isDesktop)),
                    border: Border.all(color: Colors.white.withAlpha(8)),
                  ),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Text(
                      whatsNew,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13.0.rx(isDesktop),
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 24.0.rh(isDesktop)),
                !isDesktop
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(
                                12.rr(isDesktop),
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                _launchUpdateUrl();
                              },
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  vertical: 12.rh(isDesktop),
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      AppColors.primary,
                                      AppColors.primaryLight,
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    12.rr(isDesktop),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primary.withAlpha(60),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    'Update Now',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14.0.rx(isDesktop),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: 8.rh(isDesktop)),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.symmetric(
                                vertical: 12.rh(isDesktop),
                              ),
                            ),
                            child: Text(
                              'Later',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 14.0.rx(isDesktop),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.symmetric(
                                horizontal: 16.rw(isDesktop),
                                vertical: 10.rh(isDesktop),
                              ),
                            ),
                            child: Text(
                              'Later',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 14.0.rx(isDesktop),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          SizedBox(width: 8.rw(isDesktop)),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(
                                12.rr(isDesktop),
                              ),
                              onTap: () {
                                Navigator.of(context).pop();
                                _launchUpdateUrl();
                              },
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 20.rw(isDesktop),
                                  vertical: 12.rh(isDesktop),
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      AppColors.primary,
                                      AppColors.primaryLight,
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(
                                    12.rr(isDesktop),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primary.withAlpha(60),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  'Update Now',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14.0.rx(isDesktop),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
