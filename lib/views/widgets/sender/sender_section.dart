import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import '../common/daphq_card.dart';
import '../common/animated_press_button.dart';
import '../common/custom_snackbar.dart';
import '../common/section_title.dart';
import 'nearby_devices_list.dart';

class SenderSection extends StatefulWidget {
  final bool isDesktop;

  const SenderSection({super.key, this.isDesktop = false});

  @override
  SenderSectionState createState() => SenderSectionState();
}

class SenderSectionState extends State<SenderSection> {
  late final TextEditingController _ipController;

  @override
  void initState() {
    super.initState();
    _ipController = TextEditingController(
      text: context.read<TransferCubit>().state.targetIp,
    );
    _ipController.addListener(() {
      context.read<TransferCubit>().setTargetIp(_ipController.text);
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = widget.isDesktop;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SectionTitle(
                title: AppConstants.senderMode,
                isDesktop: isDesktop,
              ),
            ),
            BlocBuilder<TransferCubit, TransferState>(
              buildWhen: (previous, current) =>
                  previous.isAdvancedMode != current.isAdvancedMode,
              builder: (context, state) {
                return TextButton.icon(
                  onPressed: () =>
                      context.read<TransferCubit>().toggleAdvancedMode(),
                  icon: Icon(
                    state.isAdvancedMode ? Icons.close : Icons.settings,
                    size: 14.rx(isDesktop),
                    color: AppColors.primary,
                  ),
                  label: Text(
                    state.isAdvancedMode
                        ? AppConstants.cancel
                        : AppConstants.advancedMode,
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 11.rx(isDesktop),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        SizedBox(height: 8.0.rh(isDesktop)),
        BlocBuilder<TransferCubit, TransferState>(
          builder: (context, state) {
            return AnimatedSize(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: DaphqCard(
                isDesktop: isDesktop,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.isAdvancedMode) ...[
                      // Advanced Mode (Manual IP)
                      TextField(
                        controller: _ipController,
                        cursorColor: AppColors.primary,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.0.rx(isDesktop),
                        ),
                        decoration: InputDecoration(
                          labelText: AppConstants.receiverIpLabel,
                          labelStyle: TextStyle(
                            color: Colors.white60,
                            fontSize: 13.0.rx(isDesktop),
                          ),
                          filled: true,
                          fillColor: Colors.black.withAlpha(50),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              10.rr(isDesktop),
                            ),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: EdgeInsets.all(12.rr(isDesktop)),
                        ),
                        enabled: !state.isTransferring,
                      ),
                      SizedBox(height: 15.rh(isDesktop)),
                      Row(
                        children: [
                          Expanded(
                            child: _buildSendButton(
                              context,
                              Icons.file_copy,
                              AppConstants.sendFile,
                              false,
                              state,
                              isDesktop,
                            ),
                          ),
                          SizedBox(width: 10.rw(isDesktop)),
                          Expanded(
                            child: _buildSendButton(
                              context,
                              Icons.folder,
                              AppConstants.sendFolder,
                              true,
                              state,
                              isDesktop,
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      // Simple Mode (Discovery)
                      NearbyDevicesList(isDesktop: isDesktop),
                    ],
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 350),
                      switchInCurve: Curves.easeInOutCubic,
                      switchOutCurve: Curves.easeInOutCubic,
                      layoutBuilder:
                          (
                            Widget? currentChild,
                            List<Widget> previousChildren,
                          ) {
                            return Stack(
                              alignment: Alignment.topCenter,
                              children: <Widget>[
                                ...previousChildren,
                                ?currentChild,
                              ],
                            );
                          },
                      transitionBuilder:
                          (Widget child, Animation<double> animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: SizeTransition(
                                sizeFactor: animation,
                                axisAlignment: -1.0,
                                child: child,
                              ),
                            );
                          },
                      child:
                          (state.isTransferring &&
                              !state.model.status.toLowerCase().contains(
                                "receiv",
                              ))
                          ? Column(
                              key: const ValueKey('cancel_btn'),
                              children: [
                                SizedBox(height: 15.0.rh(isDesktop)),
                                AnimatedPressButton(
                                  isDesktop: isDesktop,
                                  onPressed: () {
                                    CustomSnackBar.hide();
                                    context
                                        .read<TransferCubit>()
                                        .cancelSending();
                                  },
                                  gradientColors: const [
                                    AppColors.danger,
                                    AppColors.dangerLight,
                                  ],
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.cancel,
                                        color: Colors.white,
                                        size: 24.0.rx(isDesktop),
                                      ),
                                      SizedBox(width: 8.0.rw(isDesktop)),
                                      Text(
                                        AppConstants.cancelTransfer,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16.0.rx(isDesktop),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('empty_cancel'),
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildSendButton(
    BuildContext context,
    IconData icon,
    String text,
    bool isFolder,
    TransferState state,
    bool isDesktop,
  ) {
    return AnimatedPressButton(
      isDesktop: isDesktop,
      onPressed: state.isTransferring ? null : () => _pick(context, isFolder),
      gradientColors: const [AppColors.primary, AppColors.primaryLight],
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 4.rw(isDesktop)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18.0.rx(isDesktop)),
            SizedBox(width: 4.0.rw(isDesktop)),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  text,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.0.rx(isDesktop),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, bool isFolder) async {
    final cubit = context.read<TransferCubit>();
    if (cubit.state.isTransferring) return;

    String? path;
    if (isFolder) {
      path = await FilePicker.getDirectoryPath();
    } else {
      FilePickerResult? r = await FilePicker.pickFiles();
      path = r?.files.single.path;
    }

    if (path != null) {
      if (cubit.state.targetIp.trim().isEmpty) {
        if (!context.mounted) return;
        CustomSnackBar.show(context, message: AppConstants.enterTargetIp);
        return;
      }
      if (!context.mounted) return;
      cubit.sendData(path: path, isFolder: isFolder);
    }
  }
}
