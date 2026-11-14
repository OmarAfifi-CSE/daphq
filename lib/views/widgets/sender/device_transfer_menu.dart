import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';
import '../../../core/file_utils.dart';
import '../../../fabric/peer_models.dart';
import '../common/animated_press_button.dart';
import '../common/unified_add_button.dart';

class DeviceTransferMenu extends StatelessWidget {
  final String ip;
  final String name;
  final bool isDesktop;
  final UnifiedPeer? peer;
  final ScrollController? scrollController;

  const DeviceTransferMenu({
    super.key,
    required this.ip,
    required this.name,
    required this.isDesktop,
    this.peer,
    this.scrollController,
  });

  static void show(
    BuildContext context,
    String ip,
    String name,
    bool isDesktop, {
    UnifiedPeer? peer,
  }) {
    if (isDesktop) {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: AppColors.dialogBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            width: (MediaQuery.sizeOf(context).width - 80.0)
                .clamp(0.0, 420.0)
                .toDouble(),
            height: (MediaQuery.sizeOf(context).height - 48.0)
                .clamp(0.0, 520.0)
                .toDouble(),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withAlpha(10)),
            ),
            child: DeviceTransferMenu(
              ip: ip,
              name: name,
              isDesktop: true,
              peer: peer,
            ),
          ),
        ),
      );
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: AppColors.dialogBackground,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
        ),
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => DeviceTransferMenu(
            ip: ip,
            name: name,
            isDesktop: false,
            peer: peer,
            scrollController: scrollController,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TransferCubit>();

    return BlocBuilder<TransferCubit, TransferState>(
      buildWhen: (previous, current) =>
          previous.selectedPaths != current.selectedPaths ||
          previous.selectedPathsIsDir != current.selectedPathsIsDir ||
          previous.isTransferring != current.isTransferring ||
          previous.isAddingFiles != current.isAddingFiles,
      builder: (context, state) {
        return Container(
          padding: EdgeInsets.all(20.rr(isDesktop)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              if (!isDesktop) ...[
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8.rr(isDesktop)),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withAlpha(15),
                        borderRadius: BorderRadius.circular(10.rr(isDesktop)),
                      ),
                      child: Icon(
                        Icons.send_rounded,
                        color: AppColors.primaryLight,
                        size: 18.rx(isDesktop),
                      ),
                    ),
                    SizedBox(width: 10.rw(isDesktop)),
                    Expanded(
                      child: Text(
                        "Send to $name",
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17.rx(isDesktop),
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (state.selectedPaths.isNotEmpty) ...[
                  SizedBox(height: 8.rh(isDesktop)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => cubit.clearSelection(),
                      icon: Icon(
                        Icons.clear_all_rounded,
                        color: AppColors.danger,
                        size: 16.rx(isDesktop),
                      ),
                      label: Text(
                        "Clear All",
                        style: TextStyle(
                          color: AppColors.danger,
                          fontSize: 13.rx(isDesktop),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ],
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            padding: EdgeInsets.all(8.rr(isDesktop)),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withAlpha(15),
                              borderRadius: BorderRadius.circular(
                                10.rr(isDesktop),
                              ),
                            ),
                            child: Icon(
                              Icons.send_rounded,
                              color: AppColors.primaryLight,
                              size: 18.rx(isDesktop),
                            ),
                          ),
                          SizedBox(width: 10.rw(isDesktop)),
                          Expanded(
                            child: Text(
                              "Send to $name",
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 17.rx(isDesktop),
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        if (state.selectedPaths.isNotEmpty)
                          TextButton(
                            onPressed: () => cubit.clearSelection(),
                            child: Text(
                              "Clear All",
                              style: TextStyle(
                                color: AppColors.danger,
                                fontSize: 13.rx(isDesktop),
                              ),
                            ),
                          ),
                        SizedBox(width: 8.rw(isDesktop)),
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            color: AppColors.textMuted,
                            size: 20.rx(isDesktop),
                          ),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
              Divider(color: Colors.white.withAlpha(8), height: 28),

              // Add Buttons
              UnifiedAddButton(isDesktop: isDesktop),

              SizedBox(height: 20.rh(isDesktop)),

              // Selected Items List
              Expanded(
                child: state.isAddingFiles
                    ? SingleChildScrollView(
                        controller: scrollController,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.primaryLight,
                                ),
                              ),
                              SizedBox(height: 16.rh(isDesktop)),
                              Text(
                                "Processing files...",
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 14.rx(isDesktop),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : state.selectedPaths.isEmpty
                    ? SingleChildScrollView(
                        controller: scrollController,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: EdgeInsets.all(16.rr(isDesktop)),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary.withAlpha(8),
                                ),
                                child: Icon(
                                  Icons.cloud_upload_outlined,
                                  size: 40.rx(isDesktop),
                                  color: AppColors.textMuted.withAlpha(60),
                                ),
                              ),
                              SizedBox(height: 12.rh(isDesktop)),
                              Text(
                                "No items selected yet",
                                style: TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 14.rx(isDesktop),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: state.selectedPaths.length,
                        itemBuilder: (context, index) {
                          final path = state.selectedPaths[index];
                          final isDir = state.selectedPathsIsDir[path] ?? false;
                          final segments = path
                              .split(RegExp(r'[\\/]+'))
                              .where((s) => s.isNotEmpty)
                              .toList();
                          final name = segments.isNotEmpty
                              ? segments.last
                              : path.replaceAll(RegExp(r'[\\/]+$'), '');

                          // Staggered entrance animation removed for performance on large lists
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 4.rw(isDesktop),
                                  vertical: 2.rh(isDesktop),
                                ),
                                leading: Container(
                                  padding: EdgeInsets.all(10.rr(isDesktop)),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withAlpha(15),
                                    borderRadius: BorderRadius.circular(
                                      12.rr(isDesktop),
                                    ),
                                    border: Border.all(
                                      color: AppColors.primary.withAlpha(30),
                                    ),
                                  ),
                                  child: Icon(
                                    isDir
                                        ? Icons.folder_copy_rounded
                                        : FileUtils.getFileIcon(name),
                                    color: AppColors.primary,
                                    size: 18.rx(isDesktop),
                                  ),
                                ),
                                title: Text(
                                  name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 13.rx(isDesktop),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    Icons.close_rounded,
                                    color: AppColors.textMuted,
                                    size: 16.rx(isDesktop),
                                  ),
                                  onPressed: () =>
                                      cubit.removeSelectedPath(path),
                                ),
                              ),
                              Divider(
                                color: Colors.white.withAlpha(6),
                                height: 1,
                              ),
                            ],
                          );
                        },
                      ),
              ),

              // Send Button
              SizedBox(height: 16.rh(isDesktop)),
              AnimatedPressButton(
                isDesktop: isDesktop,
                onPressed: state.selectedPaths.isEmpty || state.isTransferring
                    ? null
                    : () {
                        if (peer != null) {
                          cubit.sendToPeer(peer!);
                        } else {
                          cubit.setTargetIp(ip);
                          cubit.sendData();
                        }
                        Navigator.pop(context);
                      },
                gradientColors: const [
                  AppColors.primary,
                  AppColors.primaryLight,
                ],
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.send_rounded,
                      color: Colors.white,
                      size: 18.rx(isDesktop),
                    ),
                    SizedBox(width: 10.rw(isDesktop)),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          state.selectedPaths.isEmpty
                              ? "Select Items to Send"
                              : "Send ${state.selectedPaths.length} Items",
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15.rx(isDesktop),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
