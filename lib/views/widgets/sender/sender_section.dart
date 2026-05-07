import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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
import 'device_transfer_menu.dart';

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
                      
                      // Manual IP "Continue" Button
                      AnimatedPressButton(
                        isDesktop: isDesktop,
                        onPressed: () {
                          final ip = _ipController.text.trim();
                          if (ip.isEmpty) {
                            CustomSnackBar.show(context, message: AppConstants.enterTargetIp);
                            return;
                          }
                          DeviceTransferMenu.show(context, ip, "Manual Receiver", isDesktop);
                        },
                        gradientColors: const [AppColors.primary, AppColors.primaryLight],
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.open_in_new_rounded, color: Colors.white, size: 20.rx(isDesktop)),
                            SizedBox(width: 10.rw(isDesktop)),
                            Text(
                              "Select Content & Send",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14.rx(isDesktop),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      // Simple Mode (Discovery)
                      NearbyDevicesList(isDesktop: isDesktop),
                    ],
                    // Selection Banner
                    if (state.selectedPaths.isNotEmpty && !state.isTransferring) ...[
                      SizedBox(height: 15.rh(isDesktop)),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 12.rw(isDesktop), vertical: 8.rh(isDesktop)),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(20),
                          borderRadius: BorderRadius.circular(10.rr(isDesktop)),
                          border: Border.all(color: AppColors.primary.withAlpha(50)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle_outline_rounded, color: AppColors.primary, size: 18.rx(isDesktop)),
                            SizedBox(width: 10.rw(isDesktop)),
                            Expanded(
                              child: Text(
                                "${state.selectedPaths.length} items ready to send",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.rx(isDesktop),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => context.read<TransferCubit>().clearSelection(),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.symmetric(horizontal: 10.rw(isDesktop)),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                "Clear",
                                style: TextStyle(color: AppColors.danger, fontSize: 12.rx(isDesktop)),
                              ),
                            ),
                          ],
                        ),
                      ),
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
                      child: state.isTransferring
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
}
