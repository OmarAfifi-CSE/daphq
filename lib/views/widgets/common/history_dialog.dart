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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text(
          'Clear History',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to clear your transfer history?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Clear',
              style: TextStyle(color: AppColors.dangerLight),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open location.'),
            backgroundColor: AppColors.danger,
          ),
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
            color: AppColors.background.withAlpha(242), // ~0.95 opacity
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(128), // 0.5 opacity
                blurRadius: 20,
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
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
          border: Border(
            top: BorderSide(color: AppColors.cardBorder, width: 1.5),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            // Bottom sheet drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
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
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: widget.isDesktop ? 18 : 18.sp,
                ),
              ),
              Row(
                children: [
                  if (_history.isNotEmpty)
                    IconButton(
                      icon: Icon(
                        Icons.delete_sweep_rounded,
                        color: Colors.white70,
                        size: widget.isDesktop ? 22 : 22.sp,
                      ),
                      tooltip: 'Clear history',
                      onPressed: _clearAll,
                    ),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
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
        Container(height: 1, color: AppColors.cardBorder),
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
                  itemBuilder: (context, index) {
                    final entry = _history[index];
                    return _buildHistoryItem(entry);
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
          Icon(
            Icons.history_rounded,
            size: widget.isDesktop ? 60 : 60.sp,
            color: Colors.white24,
          ),
          const SizedBox(height: 12),
          Text(
            'No transfers yet',
            style: TextStyle(
              color: Colors.white38,
              fontSize: widget.isDesktop ? 14 : 14.sp,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryItem(HistoryEntry entry) {
    final bool isSend = entry.direction == 'send';
    final bool isSuccess = entry.status == 'success';
    final bool isCancelled = entry.status == 'cancelled';

    Color statusColor = AppColors.successLight;
    IconData statusIcon = Icons.check_circle_rounded;
    String statusText = 'Completed';

    if (!isSuccess) {
      if (isCancelled) {
        statusColor = Colors.orangeAccent;
        statusIcon = Icons.cancel_rounded;
        statusText = 'Cancelled';
      } else {
        statusColor = AppColors.dangerLight;
        statusIcon = Icons.error_rounded;
        statusText = 'Failed';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.cardOverlay,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: ListTile(
        contentPadding: EdgeInsets.symmetric(
          horizontal: widget.isDesktop ? 12.0 : 12.w,
          vertical: 4,
        ),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (isSend ? Colors.blueAccent : AppColors.primary).withAlpha(
              25,
            ),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isSend ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            color: isSend ? Colors.blueAccent : Colors.tealAccent,
            size: widget.isDesktop ? 20 : 20.sp,
          ),
        ),
        title: Text(
          entry.fileName,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
            fontSize: widget.isDesktop ? 14 : 14.sp,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.formattedSize,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: widget.isDesktop ? 12 : 11.sp,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 3,
                    height: 3,
                    decoration: const BoxDecoration(
                      color: Colors.white24,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    entry.formattedDate,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: widget.isDesktop ? 12 : 11.sp,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    statusIcon,
                    color: statusColor,
                    size: widget.isDesktop ? 13 : 13.sp,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: widget.isDesktop ? 11 : 10.sp,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        trailing: (isSuccess && entry.localPath != null)
            ? InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _openFolder(entry.localPath!),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Icon(
                    Icons.folder_open_rounded,
                    color: Colors.blueAccent,
                    size: widget.isDesktop ? 22 : 22.sp,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
