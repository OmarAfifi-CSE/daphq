import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_colors.dart';
import '../../core/responsive_utils.dart';

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
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.dialogBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.0.rr(isDesktop)),
      ),
      title: Row(
        children: [
          Icon(Icons.system_update_alt, color: Colors.blueAccent, size: 28.0.rx(isDesktop)),
          SizedBox(width: 12.0.rw(isDesktop)),
          Expanded(
            child: Text(
              'Update Available',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 20.0.rx(isDesktop),
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: 300.0.rh(isDesktop),
          maxWidth: isDesktop ? 600 : double.infinity,
        ),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Version $newVersion is now available on GitHub.',
                style: TextStyle(color: Colors.white70, fontSize: 14.0.rx(isDesktop)),
              ),
              SizedBox(height: 16.0.rh(isDesktop)),
              Text(
                "What's New:",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16.0.rx(isDesktop),
                ),
              ),
              SizedBox(height: 8.0.rh(isDesktop)),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(12.0.rw(isDesktop)),
                decoration: BoxDecoration(
                  color: AppColors.cardOverlay,
                  borderRadius: BorderRadius.circular(8.0.rr(isDesktop)),
                ),
                child: Text(
                  whatsNew,
                  style: TextStyle(color: Colors.white70, fontSize: 13.0.rx(isDesktop)),
                ),
              ),
            ],
          ),
        ),
      ),
      actionsPadding: EdgeInsets.symmetric(horizontal: 16.0.rw(isDesktop), vertical: 12.0.rh(isDesktop)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            minimumSize: Size(60.0.rw(isDesktop), 44.0.rh(isDesktop)),
          ),
          child: Text(
            'Later',
            style: TextStyle(color: Colors.white54, fontSize: 14.0.rx(isDesktop)),
          ),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pop();
            _launchUpdateUrl();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.white,
            minimumSize: Size(100.0.rw(isDesktop), 44.0.rh(isDesktop)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8.0.rr(isDesktop)),
            ),
          ),
          child: Text(
            'Update Now',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.0.rx(isDesktop)),
          ),
        ),
      ],
    );
  }
}
