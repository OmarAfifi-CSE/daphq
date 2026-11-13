import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../services/history_service.dart';
import '../../../core/file_utils.dart';
import 'custom_snackbar.dart';
import 'package:open_filex/open_filex.dart';

class HistoryDialog extends StatefulWidget {
  final bool isDesktop;

  const HistoryDialog({super.key, required this.isDesktop});

  static Future<void> show(
    BuildContext context, {
    required bool isDesktop,
  }) async {
    if (isDesktop) {
      return showDialog(
        context: context,
        builder: (context) => const HistoryDialog(isDesktop: true),
      );
    } else {
      return showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => const HistoryDialog(isDesktop: false),
      );
    }
  }

  @override
  State<HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<HistoryDialog> {
  List<HistoryEntry> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final data = await HistoryService.loadHistory();
    if (mounted) {
      setState(() {
        _history = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.dialogBackground,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Clear History',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          'Are you sure you want to clear your transfer history?',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Clear',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await HistoryService.clearHistory();
      _loadData();
    }
  }

  Future<void> _openFile(String path) async {
    try {
      if (await FileSystemEntity.isDirectory(path)) {
        await _openFolder(path);
        return;
      }
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done &&
          result.type != ResultType.noAppToOpen &&
          mounted) {
        CustomSnackBar.show(
          context,
          message: 'Could not open file: ${result.message}',
          backgroundColor: AppColors.danger,
        );
      }
    } catch (_) {
      if (mounted) {
        CustomSnackBar.show(
          context,
          message: 'Could not open file.',
          backgroundColor: AppColors.danger,
        );
      }
    }
  }

  Future<void> _openFolder(String path) async {
    try {
      String targetPath = path;
      if (await FileSystemEntity.isFile(path)) {
        targetPath = p.dirname(path);
      } else if (!await FileSystemEntity.isDirectory(path)) {
        // Fallback to parent directory if folder/file doesn't exist yet on disk
        targetPath = p.dirname(path);
      }

      // Normalize path (very important on Windows to use backslashes instead of mixed forward slashes!)
      targetPath = p.normalize(targetPath);
      if (Platform.isWindows) {
        targetPath = targetPath.replaceAll('/', '\\');
      }

      if (Platform.isWindows) {
        await Process.run('explorer.exe', [targetPath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [targetPath]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [targetPath]);
      } else if (Platform.isAndroid) {
        const platform = MethodChannel('com.omarafifi.daphq/file_manager');
        await platform.invokeMethod('openFolder', {'path': targetPath});
      }
    } catch (_) {
      if (mounted) {
        CustomSnackBar.show(
          context,
          message: 'Could not open location.',
          backgroundColor: AppColors.danger,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (widget.isDesktop) {
      content = Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
        child: Container(
          width: 500,
          height: 600,
          decoration: BoxDecoration(
            color: AppColors.background.withAlpha(245),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withAlpha(12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(120),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: _buildMainContent(),
        ),
      );
    } else {
      // Mobile Bottom Sheet
      content = Container(
        height: MediaQuery.of(context).size.height * 0.75,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24),
            topRight: Radius.circular(24),
          ),
          border: Border(
            top: BorderSide(color: Colors.white.withAlpha(12), width: 1.5),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            // Bottom sheet drag handle
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textMuted.withAlpha(60),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(child: _buildMainContent()),
          ],
        ),
      );
    }

    return BlocListener<TransferCubit, TransferState>(
      listenWhen: (previous, current) {
        final wasActive = previous.isTransferring || previous.isReceivingActive;
        final isActive = current.isTransferring || current.isReceivingActive;
        // Trigger reload when active state transitions to inactive (completion, fail, cancel)
        return wasActive && !isActive;
      },
      listener: (context, state) async {
        await Future.delayed(const Duration(milliseconds: 100));
        _loadData();
      },
      child: content,
    );
  }

  Widget _buildMainContent() {
    return Column(
      children: [
        // Header Row
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.isDesktop ? 20.0 : 20.w,
            vertical: widget.isDesktop ? 16.0 : 16.h,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Transfer History',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: widget.isDesktop ? 18 : 18.sp,
                ),
              ),
              Row(
                children: [
                  if (_history.isNotEmpty)
                    IconButton(
                      icon: Icon(
                        Icons.delete_sweep_rounded,
                        color: AppColors.textMuted,
                        size: widget.isDesktop ? 22 : 22.sp,
                      ),
                      tooltip: 'Clear history',
                      onPressed: _clearAll,
                    ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: AppColors.textMuted,
                      size: widget.isDesktop ? 22 : 22.sp,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Divider
        Container(height: 1, color: Colors.white.withAlpha(8)),
        // History List
        Expanded(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                )
              : _history.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.isDesktop ? 16.0 : 16.w,
                    vertical: 10,
                  ),
                  itemCount: _history.length,
                  prototypeItem: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.transparent),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.isDesktop ? 14.0 : 12.w,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 48, height: 48),
                          SizedBox(width: widget.isDesktop ? 16 : 14.w),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('', maxLines: 2),
                                SizedBox(height: 4),
                                Text('', maxLines: 1),
                                SizedBox(height: 4),
                                Text('', maxLines: 1),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  itemBuilder: (context, index) {
                    return _buildHistoryItem(_history[index], index);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary.withAlpha(8),
            ),
            child: Icon(
              Icons.history_rounded,
              size: widget.isDesktop ? 48 : 48.sp,
              color: AppColors.textMuted.withAlpha(60),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'No transfers yet',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: widget.isDesktop ? 14 : 14.sp,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryItem(HistoryEntry entry, int index) {
    final bool isSend = entry.direction == 'send';
    final bool isSuccess = entry.status == 'success';
    final bool isCancelled = entry.status == 'cancelled';

    Color statusColor = AppColors.success;
    IconData statusIcon = Icons.check_circle_rounded;
    String statusText = 'Completed';

    if (!isSuccess) {
      if (isCancelled) {
        statusColor = const Color(0xFFFFB347);
        statusIcon = Icons.cancel_rounded;
        statusText = 'Cancelled';
      } else {
        statusColor = AppColors.danger;
        statusIcon = Icons.error_rounded;
        statusText = 'Failed';
      }
    }

    // Staggered entrance animation removed for performance on large lists
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(8)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: AppColors.primary.withAlpha(8),
          onTap: (isSuccess && entry.localPath != null)
              ? () => _openFile(entry.localPath!)
              : null,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.isDesktop ? 14.0 : 12.w,
              vertical: 10,
            ),
            child: Row(
              children: [
                // Premium Icon with Direction Badge
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (isSend ? AppColors.primary : AppColors.success)
                            .withAlpha(15),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color:
                              (isSend ? AppColors.primary : AppColors.success)
                                  .withAlpha(30),
                        ),
                      ),
                      child: Icon(
                        FileUtils.getFileIcon(entry.fileName),
                        color: isSend ? AppColors.primary : AppColors.success,
                        size: widget.isDesktop ? 22 : 20.sp,
                      ),
                    ),
                    Positioned(
                      bottom: -4,
                      right: -4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: isSend ? AppColors.primary : AppColors.success,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.background,
                            width: 2.5,
                          ),
                        ),
                        child: Icon(
                          isSend
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          color: Colors.white,
                          size: widget.isDesktop ? 10 : 9.sp,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(width: widget.isDesktop ? 16 : 14.w),
                // Details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.fileName,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: widget.isDesktop ? 14 : 14.sp,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          Text(
                            entry.formattedSize,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: widget.isDesktop ? 12 : 11.sp,
                            ),
                          ),
                          Container(
                            width: 3,
                            height: 3,
                            decoration: BoxDecoration(
                              color: AppColors.textMuted.withAlpha(60),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Text(
                            entry.formattedDate,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: widget.isDesktop ? 12 : 11.sp,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Status pill
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withAlpha(15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              statusIcon,
                              color: statusColor,
                              size: widget.isDesktop ? 11 : 11.sp,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              statusText,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: widget.isDesktop ? 10 : 10.sp,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // Folder open icon
                if (isSuccess && entry.localPath != null)
                  IconButton(
                    icon: Icon(
                      Icons.folder_open_rounded,
                      color: AppColors.primaryLight.withAlpha(120),
                      size: widget.isDesktop ? 20 : 20.sp,
                    ),
                    tooltip: 'Show in folder',
                    onPressed: () => _openFolder(entry.localPath!),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
