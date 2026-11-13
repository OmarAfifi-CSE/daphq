import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import '../views/widgets/common/update_dialog.dart';
import '../core/app_constants.dart';

class UpdateService {
  /// Computes the lowercase hex SHA-256 digest of [path] (plan T-011).
  static Future<String> computeFileSha256(String path) async {
    final stream = File(path).openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString().toLowerCase();
  }

  /// Extracts a valid 64-character hex SHA-256 digest from a `.sha256` file
  /// body (`"<hex>  filename"` or raw hex), or returns null if invalid.
  static String? parseSha256Digest(String rawBody) {
    final candidate = rawBody.trim().split(RegExp(r'\s+')).first.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate)) {
      return null;
    }
    return candidate;
  }

  /// Finds the sibling `<asset>.sha256` download URL for [downloadUrl], or
  /// returns an empty string when none is published.
  static String findSha256AssetUrl(List<dynamic> assets, String downloadUrl) {
    final downloadAssetName =
        Uri.tryParse(downloadUrl)?.pathSegments.lastOrNull?.toLowerCase() ??
            downloadUrl.split('/').last.toLowerCase();
    if (downloadAssetName.isEmpty) return '';
    for (final asset in assets) {
      if (asset is! Map) continue;
      final String name = asset['name']?.toString().toLowerCase() ?? '';
      if (name == '$downloadAssetName.sha256') {
        return asset['browser_download_url']?.toString() ?? '';
      }
    }
    return '';
  }

  /// Checks for updates and shows a dialog if a newer version is available.
  static Future<void> checkForUpdates(BuildContext context) async {
    try {
      final response = await http
          .get(Uri.parse(AppConstants.githubApiUrl))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final String remoteVersionTag = data['tag_name'] as String;
        final String releaseNotes =
            data['body'] ?? 'No release notes available.';

        // Smart URL detection based on platform
        String downloadUrl = '';
        final List<dynamic> assets = data['assets'] ?? [];
        bool hasAssetForPlatform = false;

        if (Platform.isAndroid) {
          // Look for APK
          for (var asset in assets) {
            final String name = asset['name']?.toString().toLowerCase() ?? '';
            if (name.endsWith('.apk')) {
              downloadUrl = asset['browser_download_url'];
              hasAssetForPlatform = true;
              break;
            }
          }
        } else if (Platform.isWindows) {
          // Look for Windows installer/archive
          for (var asset in assets) {
            final String name = asset['name']?.toString().toLowerCase() ?? '';
            if (name.endsWith('.exe')) {
              downloadUrl = asset['browser_download_url'];
              hasAssetForPlatform = true;
              break;
            }
          }
        }

        // If the latest release doesn't contain a file for this platform,
        // ignore the update entirely.
        if (!hasAssetForPlatform) {
          return;
        }

        // Plan T-011: releases publish '<asset>.sha256' siblings; when one
        // exists for the chosen download, the dialog verifies the download
        // against it before installing.
        final String expectedSha256Url =
            findSha256AssetUrl(assets, downloadUrl);

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
              expectedSha256Url: expectedSha256Url,
              isDesktop: isDesktopOS,
            ),
          );
        }
      }
    } catch (_) {
      // Silently fail
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
      List<int> localParts = local
          .split('.')
          .map((e) => int.tryParse(e) ?? 0)
          .toList();
      List<int> remoteParts = remote
          .split('.')
          .map((e) => int.tryParse(e) ?? 0)
          .toList();

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
    } catch (_) {
      return false;
    }
  }
}
