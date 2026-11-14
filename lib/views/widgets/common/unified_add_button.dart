import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'dart:io';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import 'animated_press_button.dart';

class UnifiedAddButton extends StatefulWidget {
  final bool isDesktop;

  const UnifiedAddButton({super.key, required this.isDesktop});

  @override
  State<UnifiedAddButton> createState() => _UnifiedAddButtonState();
}

class _UnifiedAddButtonState extends State<UnifiedAddButton> {
  final GlobalKey<PopupMenuButtonState> _menuKey = GlobalKey();
  bool _isDispatchingPicker = false;

  void _handleSelection(int value, TransferCubit cubit) {
    if (_isDispatchingPicker) return;
    _isDispatchingPicker = true;
    // Defer native modal picker outside active pointer callbacks (Inv-8).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isDispatchingPicker = false;
      if (!mounted) return;
      if (value == 1) cubit.pickItems(FileType.any);
      if (value == 2) cubit.pickFolder();
      if (value == 3) cubit.pickItems(FileType.image);
      if (value == 4) cubit.pickItems(FileType.video);
    });
  }

  void _showMobileMenu(BuildContext context, TransferCubit cubit) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.dialogBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.textMuted.withAlpha(60),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                _buildMobileItem(
                  context,
                  1,
                  Icons.insert_drive_file_outlined,
                  "All Files",
                  "Browse any file",
                  cubit,
                ),
                _buildMobileItem(
                  context,
                  2,
                  Icons.folder_outlined,
                  "Folders",
                  "Select full directories",
                  cubit,
                ),
                _buildMobileItem(
                  context,
                  3,
                  Icons.image_outlined,
                  "Images",
                  "Gallery photos",
                  cubit,
                ),
                _buildMobileItem(
                  context,
                  4,
                  Icons.movie_outlined,
                  "Videos",
                  "Camera recordings",
                  cubit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileItem(
    BuildContext context,
    int value,
    IconData icon,
    String label,
    String sub,
    TransferCubit cubit,
  ) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: AppColors.primary, size: 22),
      ),
      title: Text(
        label,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        sub,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      onTap: () {
        Navigator.pop(context);
        _handleSelection(value, cubit);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        widget.isDesktop ||
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux;
    final scale = isDesktop ? context.desktopScale : 1.0;

    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        final cubit = context.read<TransferCubit>();
        final isLoading = state.isAddingFiles;

        if (!isDesktop) {
          return AnimatedPressButton(
            isDesktop: false,
            onPressed: isLoading ? null : () => _showMobileMenu(context, cubit),
            gradientColors: isLoading
                ? [
                    AppColors.textMuted.withAlpha(20),
                    AppColors.textMuted.withAlpha(20),
                  ]
                : const [AppColors.primary, AppColors.primaryLight],
            child: _buildButtonContent(false, 1.0, isLoading: isLoading),
          );
        }

        return Theme(
          data: Theme.of(context).copyWith(
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
          ),
          child: PopupMenuButton<int>(
            key: _menuKey,
            enabled: !isLoading,
            offset: Offset(0, 55.rh(isDesktop, desktopScale: scale)),
            color: AppColors.dialogBackground,
            elevation: 20,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                18.rr(isDesktop, desktopScale: scale),
              ),
              side: BorderSide(color: Colors.white.withAlpha(10), width: 1),
            ),
            onSelected: (value) => _handleSelection(value, cubit),
            itemBuilder: (context) => [
              _buildDesktopItem(
                1,
                Icons.insert_drive_file_outlined,
                "All Files",
                "Browse any file",
                isDesktop,
                scale,
              ),
              _buildDesktopItem(
                2,
                Icons.folder_outlined,
                "Folders",
                "Select full directories",
                isDesktop,
                scale,
              ),
              _buildDesktopItem(
                3,
                Icons.image_outlined,
                "Images",
                "Gallery photos",
                isDesktop,
                scale,
              ),
              _buildDesktopItem(
                4,
                Icons.movie_outlined,
                "Videos",
                "Camera recordings",
                isDesktop,
                scale,
              ),
            ],
            child: AnimatedPressButton(
              isDesktop: isDesktop,
              onPressed: isLoading
                  ? null
                  : () => _menuKey.currentState?.showButtonMenu(),
              gradientColors: isLoading
                  ? [
                      AppColors.textMuted.withAlpha(20),
                      AppColors.textMuted.withAlpha(20),
                    ]
                  : const [AppColors.primary, AppColors.primaryLight],
              child: _buildButtonContent(
                isDesktop,
                scale,
                isLoading: isLoading,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildButtonContent(
    bool isDesktop,
    double scale, {
    bool isLoading = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        isLoading
            ? SizedBox(
                width: 20.rx(isDesktop, desktopScale: scale),
                height: 20.rx(isDesktop, desktopScale: scale),
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              )
            : Icon(
                Icons.add_box_rounded,
                color: Colors.white,
                size: 24.rx(isDesktop, desktopScale: scale),
              ),
        SizedBox(width: 12.rw(isDesktop, desktopScale: scale)),
        Flexible(
          child: Text(
            isLoading ? "Processing..." : "Add Content",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isLoading ? Colors.white70 : Colors.white,
              fontSize: 16.rx(isDesktop, desktopScale: scale),
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const Spacer(),
        if (!isLoading)
          Icon(
            Icons.keyboard_arrow_down_rounded,
            color: Colors.white70,
            size: 20.rx(isDesktop, desktopScale: scale),
          ),
      ],
    );
  }

  PopupMenuItem<int> _buildDesktopItem(
    int value,
    IconData icon,
    String label,
    String sub,
    bool isDesktop,
    double scale,
  ) {
    return PopupMenuItem(
      value: value,
      padding: EdgeInsets.symmetric(
        horizontal: 18.rw(isDesktop, desktopScale: scale),
        vertical: 10.rh(isDesktop, desktopScale: scale),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(10.rr(isDesktop, desktopScale: scale)),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(15),
              borderRadius: BorderRadius.circular(
                12.rr(isDesktop, desktopScale: scale),
              ),
            ),
            child: Icon(
              icon,
              color: AppColors.primary,
              size: 22.rx(isDesktop, desktopScale: scale),
            ),
          ),
          SizedBox(width: 18.rw(isDesktop, desktopScale: scale)),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15.rx(isDesktop, desktopScale: scale),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2.rh(isDesktop, desktopScale: scale)),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.rx(isDesktop, desktopScale: scale),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
