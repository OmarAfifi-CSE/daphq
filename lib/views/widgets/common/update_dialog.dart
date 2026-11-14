import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import '../../../services/update_service.dart';

class UpdateDialog extends StatefulWidget {
  final String newVersion;
  final String whatsNew;
  final String downloadUrl;

  /// URL of the sibling '.sha256' release asset for [downloadUrl]. Empty
  /// when the release does not publish one — in that case only the
  /// content-length check runs (plan T-011).
  final String expectedSha256Url;
  final bool isDesktop;

  const UpdateDialog({
    super.key,
    required this.newVersion,
    required this.whatsNew,
    required this.downloadUrl,
    this.expectedSha256Url = '',
    required this.isDesktop,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';
  String _errorMessage = '';

  Future<void> _launchUpdateUrlFallback() async {
    final Uri url = Uri.parse(AppConstants.websiteUrl);
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = '';
      _downloadProgress = 0.0;
      _downloadStatus = 'Starting download...';
    });

    final client = http.Client();
    File? partialFile;
    try {
      final request = http.Request('GET', Uri.parse(widget.downloadUrl));
      final http.StreamedResponse response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Download failed with status: ${response.statusCode}');
      }

      final contentLength = response.contentLength;

      Directory tempDir;
      if (Platform.isAndroid) {
        tempDir =
            (await getExternalStorageDirectory()) ??
            await getTemporaryDirectory();
      } else {
        tempDir = await getTemporaryDirectory();
      }

      final Directory updatesDir = Directory(
        p.join(tempDir.path, 'daphq_updates'),
      );
      if (!updatesDir.existsSync()) {
        updatesDir.createSync(recursive: true);
      }

      // Clean up previous update downloads in our dedicated directory
      try {
        for (final entity in updatesDir.listSync()) {
          if (entity is File) {
            entity.deleteSync();
          }
        }
      } catch (_) {}

      final rawSegment =
          Uri.tryParse(widget.downloadUrl)?.pathSegments.lastOrNull ??
              widget.downloadUrl.split('/').last;
      final safeName = rawSegment.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final String fileName = safeName.isEmpty ? 'daphq_update.bin' : safeName;
      final File targetFile = File(p.join(updatesDir.path, fileName));
      partialFile = File('${targetFile.path}.partial');
      final IOSink sink = partialFile.openWrite();

      int downloaded = 0;
      DateTime lastUiUpdate = DateTime.now();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          downloaded += chunk.length;
          // Plan T-011: throttle UI updates to ~10/s — one setState per chunk
          // on a fast connection floods the frame pipeline.
          final now = DateTime.now();
          if (now.difference(lastUiUpdate).inMilliseconds < 100 && mounted) {
            continue;
          }
          lastUiUpdate = now;
          if (mounted) {
            setState(() {
              if (contentLength != null && contentLength > 0) {
                _downloadProgress = downloaded / contentLength;
                final String downloadedMb = (downloaded / (1024 * 1024))
                    .toStringAsFixed(1);
                final String totalMb = (contentLength / (1024 * 1024))
                    .toStringAsFixed(1);
                _downloadStatus = '$downloadedMb MB / $totalMb MB';
              } else {
                final String downloadedMb = (downloaded / (1024 * 1024))
                    .toStringAsFixed(1);
                _downloadStatus = '$downloadedMb MB downloaded';
              }
            });
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // Plan T-011: verify size completeness and, when the release publishes
      // a digest, the SHA-256 of the downloaded file — BEFORE installing it.
      if (contentLength != null &&
          contentLength > 0 &&
          downloaded != contentLength) {
        throw Exception(
          'Download incomplete ($downloaded of $contentLength bytes).',
        );
      }
      if (widget.expectedSha256Url.isNotEmpty) {
        if (mounted) {
          setState(() {
            _downloadStatus = 'Verifying download...';
          });
        }
        final digestResponse = await client
            .get(Uri.parse(widget.expectedSha256Url))
            .timeout(const Duration(seconds: 15));
        if (digestResponse.statusCode != 200) {
          throw Exception('Could not fetch the release checksum.');
        }
        final expectedDigest = UpdateService.parseSha256Digest(
          digestResponse.body,
        );
        if (expectedDigest == null) {
          throw Exception('Invalid release checksum format.');
        }
        final actualDigest = await compute(
          UpdateService.computeFileSha256,
          partialFile.path,
        );
        if (actualDigest != expectedDigest) {
          throw Exception(
            'Integrity check failed. The download was removed — please try again.',
          );
        }
      }

      partialFile.renameSync(targetFile.path);
      partialFile = null;

      if (mounted) {
        setState(() {
          _downloadStatus = 'Installing...';
          _downloadProgress = 1.0;
        });
      }

      if (Platform.isWindows) {
        await Process.start(targetFile.path, []);
        exit(0);
      } else if (Platform.isAndroid) {
        final result = await OpenFilex.open(targetFile.path);
        if (result.type != ResultType.done) {
          throw Exception(result.message);
        }
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (partialFile != null) {
        try {
          if (partialFile.existsSync()) partialFile.deleteSync();
        } catch (_) {}
      }
      final String message = e.toString().replaceFirst('Exception: ', '').trim();
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _errorMessage = message.isEmpty
              ? 'Failed to download update. Please try again.'
              : message;
        });
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final double viewportWidth = MediaQuery.sizeOf(context).width;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20.rr(widget.isDesktop)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: widget.isDesktop ? 500 : viewportWidth,
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            padding: EdgeInsets.all(
              widget.isDesktop ? 24.rw(true) : 20.rw(false),
            ),
            decoration: BoxDecoration(
              color: AppColors.dialogBackground.withAlpha(230),
              borderRadius: BorderRadius.circular(20.rr(widget.isDesktop)),
              border: Border.all(color: Colors.white.withAlpha(12)),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withAlpha(10),
                  blurRadius: 40,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(10.rr(widget.isDesktop)),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(15),
                          borderRadius: BorderRadius.circular(
                            12.rr(widget.isDesktop),
                          ),
                        ),
                        child: Icon(
                          Icons.system_update_alt,
                          color: AppColors.primaryLight,
                          size: 24.0.rx(widget.isDesktop),
                        ),
                      ),
                      SizedBox(width: 14.0.rw(widget.isDesktop)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Update Available',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 18.0.rx(widget.isDesktop),
                              ),
                            ),
                            SizedBox(height: 2.rh(widget.isDesktop)),
                            Text(
                              'Version ${widget.newVersion} is now available.',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13.0.rx(widget.isDesktop),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 20.0.rh(widget.isDesktop)),
                  Text(
                    "What's New:",
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15.0.rx(widget.isDesktop),
                    ),
                  ),
                  SizedBox(height: 10.0.rh(widget.isDesktop)),
                  Container(
                    width: viewportWidth,
                    constraints: BoxConstraints(
                      // Safe to make large because the entire dialog is now scrollable
                      maxHeight: widget.isDesktop
                          ? 350.rh(true)
                          : 380.rh(false),
                    ),
                    padding: EdgeInsets.all(14.0.rw(widget.isDesktop)),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(6),
                      borderRadius: BorderRadius.circular(
                        12.0.rr(widget.isDesktop),
                      ),
                      border: Border.all(color: Colors.white.withAlpha(8)),
                    ),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: MarkdownBody(
                        data: widget.whatsNew,
                        styleSheet: MarkdownStyleSheet(
                          p: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13.0.rx(widget.isDesktop),
                            height: 1.5,
                          ),
                          listBullet: TextStyle(
                            color: AppColors.primaryLight,
                            fontSize: 13.0.rx(widget.isDesktop),
                          ),
                          strong: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.0.rx(widget.isDesktop),
                          ),
                          h1: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 18.0.rx(widget.isDesktop),
                          ),
                          h2: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 16.0.rx(widget.isDesktop),
                          ),
                          h3: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 14.0.rx(widget.isDesktop),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 24.0.rh(widget.isDesktop)),
                  if (_errorMessage.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withAlpha(15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppColors.danger.withAlpha(30),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline_rounded,
                            color: AppColors.danger,
                            size: 18.rx(widget.isDesktop),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage,
                              style: TextStyle(
                                color: AppColors.danger,
                                fontSize: 12.0.rx(widget.isDesktop),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 16.0.rh(widget.isDesktop)),
                  ],
                  if (_isDownloading)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _downloadStatus,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12.rx(widget.isDesktop),
                              ),
                            ),
                            Text(
                              '${(_downloadProgress * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                color: AppColors.primaryLight,
                                fontSize: 12.rx(widget.isDesktop),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 8.rh(widget.isDesktop)),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _downloadProgress > 0
                                ? _downloadProgress
                                : null,
                            minHeight: 6.rh(widget.isDesktop),
                            backgroundColor: AppColors.primary.withAlpha(20),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    !widget.isDesktop
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(),
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 10.rh(widget.isDesktop),
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10.rr(widget.isDesktop),
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        'Later',
                                        style: TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 13.0.rx(widget.isDesktop),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 12.rw(widget.isDesktop)),
                                  Expanded(
                                    flex: 2,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(
                                          10.rr(widget.isDesktop),
                                        ),
                                        onTap: _downloadAndInstall,
                                        child: Container(
                                          padding: EdgeInsets.symmetric(
                                            vertical: 10.rh(widget.isDesktop),
                                          ),
                                          decoration: BoxDecoration(
                                            gradient: const LinearGradient(
                                              colors: [
                                                AppColors.primary,
                                                AppColors.primaryLight,
                                              ],
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              10.rr(widget.isDesktop),
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: AppColors.primary
                                                    .withAlpha(60),
                                                blurRadius: 10,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: Text(
                                              _errorMessage.isNotEmpty
                                                  ? 'Retry'
                                                  : 'Update Now',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13.0.rx(
                                                  widget.isDesktop,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_errorMessage.isNotEmpty) ...[
                                SizedBox(height: 12.rh(widget.isDesktop)),
                                TextButton.icon(
                                  onPressed: _launchUpdateUrlFallback,
                                  icon: Icon(
                                    Icons.open_in_browser,
                                    size: 16.rx(widget.isDesktop),
                                    color: AppColors.primaryLight,
                                  ),
                                  label: Text(
                                    'Download from Website',
                                    style: TextStyle(
                                      color: AppColors.primaryLight,
                                      fontSize: 13.rx(widget.isDesktop),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    style: TextButton.styleFrom(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 16.rw(widget.isDesktop),
                                        vertical: 10.rh(widget.isDesktop),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          10.rr(widget.isDesktop),
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      'Later',
                                      style: TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 13.0.rx(widget.isDesktop),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 12.rw(widget.isDesktop)),
                                  Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(
                                        10.rr(widget.isDesktop),
                                      ),
                                      onTap: _downloadAndInstall,
                                      child: Container(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 20.rw(widget.isDesktop),
                                          vertical: 10.rh(widget.isDesktop),
                                        ),
                                        decoration: BoxDecoration(
                                          gradient: const LinearGradient(
                                            colors: [
                                              AppColors.primary,
                                              AppColors.primaryLight,
                                            ],
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10.rr(widget.isDesktop),
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: AppColors.primary
                                                  .withAlpha(60),
                                              blurRadius: 10,
                                              offset: const Offset(0, 4),
                                            ),
                                          ],
                                        ),
                                        child: Text(
                                          _errorMessage.isNotEmpty
                                              ? 'Retry'
                                              : 'Update Now',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 13.0.rx(widget.isDesktop),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_errorMessage.isNotEmpty) ...[
                                SizedBox(height: 12.rh(widget.isDesktop)),
                                TextButton.icon(
                                  onPressed: _launchUpdateUrlFallback,
                                  icon: Icon(
                                    Icons.open_in_browser,
                                    size: 16.rx(widget.isDesktop),
                                    color: AppColors.primaryLight,
                                  ),
                                  label: Text(
                                    'Download from Website',
                                    style: TextStyle(
                                      color: AppColors.primaryLight,
                                      fontSize: 13.rx(widget.isDesktop),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
