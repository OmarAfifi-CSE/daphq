import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';
import '../common/animated_press_button.dart';
import '../common/unified_add_button.dart';

class DeviceTransferMenu extends StatelessWidget {
  final String ip;
  final String name;
  final bool isDesktop;

  const DeviceTransferMenu({
    super.key,
    required this.ip,
    required this.name,
    required this.isDesktop,
  });

  static void show(
    BuildContext context,
    String ip,
    String name,
    bool isDesktop,
  ) {
    if (isDesktop) {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: AppColors.dialogBackground,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 420,
            height: 520,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white10),
            ),
            child: DeviceTransferMenu(ip: ip, name: name, isDesktop: true),
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
          builder: (context, scrollController) =>
              DeviceTransferMenu(ip: ip, name: name, isDesktop: false),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TransferCubit>();

    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        return Container(
          padding: EdgeInsets.all(20.rr(isDesktop)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    "Send to $name",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18.rx(isDesktop),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      if (state.selectedPaths.isNotEmpty)
                        TextButton(
                          onPressed: () => cubit.clearSelection(),
                          child: Text(
                            "Clear All",
                            style: TextStyle(color: AppColors.danger, fontSize: 13.rx(isDesktop)),
                          ),
                        ),
                      if (isDesktop) ...[
                        SizedBox(width: 10.rw(isDesktop)),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white60),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 30),

              // Add Buttons
              // Unified Add Button
              UnifiedAddButton(
                isDesktop: isDesktop,
              ),

              SizedBox(height: 20.rh(isDesktop)),

              // Selected Items List
              Expanded(
                child: state.selectedPaths.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.cloud_upload_outlined,
                                size: 50.rx(isDesktop), color: Colors.white24),
                            SizedBox(height: 10.rh(isDesktop)),
                            Text(
                              "No items selected yet",
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 14.rx(isDesktop)),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: state.selectedPaths.length,
                        separatorBuilder: (context, index) =>
                            const Divider(color: Colors.white10, height: 1),
                        itemBuilder: (context, index) {
                          final path = state.selectedPaths[index];
                          final isDir = FileSystemEntity.isDirectorySync(path);
                          final name = path.split(Platform.pathSeparator).last;

                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              isDir ? Icons.folder : Icons.insert_drive_file,
                              color: isDir ? AppColors.primary : Colors.white70,
                            ),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.white, fontSize: 14.rx(isDesktop)),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                              onPressed: () => cubit.removeSelectedPath(path),
                            ),
                          );
                        },
                      ),
              ),

              // Send Button
              SizedBox(height: 20.rh(isDesktop)),
              AnimatedPressButton(
                isDesktop: isDesktop,
                onPressed: state.selectedPaths.isEmpty || state.isTransferring
                    ? null
                    : () {
                        cubit.setTargetIp(ip);
                        cubit.sendData();
                        Navigator.pop(context);
                      },
                gradientColors: const [AppColors.primary, AppColors.primaryLight],
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.send_rounded, color: Colors.white, size: 20.rx(isDesktop)),
                    SizedBox(width: 10.rw(isDesktop)),
                    Text(
                      state.selectedPaths.isEmpty
                          ? "Select Items to Send"
                          : "Send ${state.selectedPaths.length} Items",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16.rx(isDesktop),
                        fontWeight: FontWeight.bold,
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

