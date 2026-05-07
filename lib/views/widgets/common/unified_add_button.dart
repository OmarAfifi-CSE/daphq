import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'dart:io';
import '../../../core/app_colors.dart';
import '../../../core/responsive_utils.dart';
import '../../../cubits/transfer_cubit.dart';
import 'animated_press_button.dart';

class UnifiedAddButton extends StatefulWidget {
  final bool isDesktop;

  const UnifiedAddButton({
    super.key,
    required this.isDesktop,
  });

  @override
  State<UnifiedAddButton> createState() => _UnifiedAddButtonState();
}

class _UnifiedAddButtonState extends State<UnifiedAddButton> {
  final GlobalKey<PopupMenuButtonState> _menuKey = GlobalKey();

  void _handleSelection(int value, TransferCubit cubit) {
    if (value == 1) cubit.pickItems(FileType.any);
    if (value == 2) cubit.pickFolder();
    if (value == 3) cubit.pickItems(FileType.image);
    if (value == 4) cubit.pickItems(FileType.video);
  }

  void _showMobileMenu(BuildContext context, TransferCubit cubit) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.dialogBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildMobileItem(context, 1, Icons.insert_drive_file_outlined, "All Files", "Browse any file", cubit),
                _buildMobileItem(context, 2, Icons.folder_outlined, "Folders", "Select full directories", cubit),
                _buildMobileItem(context, 3, Icons.image_outlined, "Images", "Gallery photos", cubit),
                _buildMobileItem(context, 4, Icons.movie_outlined, "Videos", "Camera recordings", cubit),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileItem(BuildContext context, int value, IconData icon, String label, String sub, TransferCubit cubit) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(25),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: AppColors.primary, size: 22),
      ),
      title: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
      subtitle: Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      onTap: () {
        Navigator.pop(context);
        _handleSelection(value, cubit);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<TransferCubit>();
    final isDesktop = widget.isDesktop || Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    if (!isDesktop) {
      return AnimatedPressButton(
        isDesktop: false,
        onPressed: () => _showMobileMenu(context, cubit),
        gradientColors: const [AppColors.primary, AppColors.primaryLight],
        child: _buildButtonContent(false),
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
        offset: Offset(0, 55.rh(widget.isDesktop)),
        color: AppColors.dialogBackground,
        elevation: 20,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18.rr(widget.isDesktop)),
          side: BorderSide(color: Colors.white.withAlpha(20), width: 1),
        ),
        onSelected: (value) => _handleSelection(value, cubit),
        itemBuilder: (context) => [
          _buildDesktopItem(1, Icons.insert_drive_file_outlined, "All Files", "Browse any file"),
          _buildDesktopItem(2, Icons.folder_outlined, "Folders", "Select full directories"),
          _buildDesktopItem(3, Icons.image_outlined, "Images", "Gallery photos"),
          _buildDesktopItem(4, Icons.movie_outlined, "Videos", "Camera recordings"),
        ],
        child: AnimatedPressButton(
          isDesktop: widget.isDesktop,
          onPressed: () => _menuKey.currentState?.showButtonMenu(),
          gradientColors: const [AppColors.primary, AppColors.primaryLight],
          child: _buildButtonContent(widget.isDesktop),
        ),
      ),
    );
  }

  Widget _buildButtonContent(bool isDesktop) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 12.rh(isDesktop), horizontal: 20.rw(isDesktop)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_box_rounded, color: Colors.white, size: 24.rx(isDesktop)),
          SizedBox(width: 12.rw(isDesktop)),
          Text(
            "Add Content",
            style: TextStyle(
              color: Colors.white,
              fontSize: 16.rx(isDesktop),
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const Spacer(),
          Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70, size: 20.rx(isDesktop)),
        ],
      ),
    );
  }

  PopupMenuItem<int> _buildDesktopItem(int value, IconData icon, String label, String sub) {
    final isDesktop = widget.isDesktop;
    return PopupMenuItem(
      value: value,
      padding: EdgeInsets.symmetric(horizontal: 18.rw(isDesktop), vertical: 10.rh(isDesktop)),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(10.rr(isDesktop)),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(25),
              borderRadius: BorderRadius.circular(12.rr(isDesktop)),
            ),
            child: Icon(icon, color: AppColors.primary, size: 22.rx(isDesktop)),
          ),
          SizedBox(width: 18.rw(isDesktop)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15.rx(isDesktop),
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 2.rh(isDesktop)),
              Text(
                sub,
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11.rx(isDesktop),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
