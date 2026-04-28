import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import '../views/widgets/update_dialog.dart';

class UpdateService {
  static const String _githubApiUrl =
      'https://api.github.com/repos/OmarAfifi-CSE/daphq/releases/latest';

  /// Checks for updates and shows a dialog if a newer version is available.
  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      final response = await http.get(Uri.parse(_githubApiUrl)).timeout(
            const Duration(seconds: 10),
          );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final String remoteVersionTag = data['tag_name'] as String;
        final String releaseNotes = data['body'] ?? 'No release notes available.';
        final String downloadUrl = data['html_url'] as String;

        // Strip non-numeric prefix like 'v'
        final String remoteVersion = _cleanVersion(remoteVersionTag);

        final PackageInfo packageInfo = await PackageInfo.fromPlatform();
        final String localVersion = _cleanVersion(packageInfo.version);

        if (_isRemoteGreater(localVersion, remoteVersion)) {
          if (!context.mounted) return;
          final bool isDesktopOS = 
              Platform.isWindows || Platform.isMacOS || Platform.isLinux;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => UpdateDialog(
              newVersion: remoteVersionTag,
              whatsNew: releaseNotes,
              downloadUrl: downloadUrl,
              isDesktop: isDesktopOS,
            ),
          );
        }
      }
    } catch (e) {
      // Silently fail if network is down or API limits are reached
      debugPrint('Error checking for updates: $e');
    }
  }

  /// Removes common prefixes from a version string (e.g. 'v1.0.0-beta' -> '1.0.0')
  static String _cleanVersion(String version) {
    String cleanStr = version.toLowerCase().trim();
    if (cleanStr.startsWith('v')) {
      cleanStr = cleanStr.substring(1);
    }
    // Remove build numbers if any (e.g. '1.0.0+1' -> '1.0.0')
    if (cleanStr.contains('+')) {
      cleanStr = cleanStr.split('+').first;
    }
    // Remove pre-release tags (e.g. '1.0.0-beta' -> '1.0.0')
    if (cleanStr.contains('-')) {
      cleanStr = cleanStr.split('-').first;
    }
    return cleanStr;
  }

  /// Compares standard semantic versions. Returns true if remote > local.
  static bool _isRemoteGreater(String local, String remote) {
    try {
      List<int> localParts = local.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      List<int> remoteParts = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      int maxLength = localParts.length > remoteParts.length
          ? localParts.length
          : remoteParts.length;

      for (int i = 0; i < maxLength; i++) {
        int l = i < localParts.length ? localParts[i] : 0;
        int r = i < remoteParts.length ? remoteParts[i] : 0;

        if (r > l) return true;
        if (r < l) return false;
      }
      return false;
    } catch (e) {
      debugPrint('Error parsing versions: $e');
      return false;
    }
  }
}
