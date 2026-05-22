import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import 'daphq_card.dart';
import 'animated_press_button.dart';
import 'custom_snackbar.dart';
import 'orbital_radar.dart';
import '../sender/device_transfer_menu.dart';

class UnifiedDashboard extends StatefulWidget {
  final bool isDesktop;

  const UnifiedDashboard({super.key, this.isDesktop = false});

  @override
  State<UnifiedDashboard> createState() => _UnifiedDashboardState();
}

class _UnifiedDashboardState extends State<UnifiedDashboard> {
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
    final cubit = context.read<TransferCubit>();

    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        if (state.isAdvancedMode) {
          // If advanced mode (Manual IP), show the classic, beautiful DaphqCard form
          return DaphqCard(
            isDesktop: isDesktop,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Minimal header for manual mode to go back
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Manual IP Transfer",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15.rx(isDesktop),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: Colors.white70,
                        size: 20.rx(isDesktop),
                      ),
                      onPressed: () => cubit.toggleAdvancedMode(),
                    ),
                  ],
                ),
                const Divider(color: Colors.white10, height: 16),
                SizedBox(height: 8.rh(isDesktop)),
                TextField(
                  controller: _ipController,
                  cursorColor: AppColors.primary,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.0.rx(isDesktop),
                  ),
                  decoration: InputDecoration(
                    labelText: AppConstants.receiverIpLabel,
                    labelStyle: TextStyle(
                      color: Colors.white60,
                      fontSize: 12.0.rx(isDesktop),
                    ),
                    helperText: AppConstants.receiverIpHelper,
                    helperStyle: TextStyle(
                      color: Colors.white38,
                      fontSize: 10.0.rx(isDesktop),
                    ),
                    filled: true,
                    fillColor: Colors.black.withAlpha(50),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8.rr(isDesktop)),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: EdgeInsets.all(10.rr(isDesktop)),
                  ),
                  enabled: !state.isTransferring,
                ),
                SizedBox(height: 12.rh(isDesktop)),
                AnimatedPressButton(
                  isDesktop: isDesktop,
                  onPressed: () {
                    final ip = _ipController.text.trim();
                    if (ip.isEmpty) {
                      CustomSnackBar.show(
                        context,
                        message: AppConstants.enterTargetIp,
                      );
                      return;
                    }
                    DeviceTransferMenu.show(
                      context,
                      ip,
                      "Manual Receiver",
                      isDesktop,
                    );
                  },
                  gradientColors: const [
                    AppColors.primary,
                    AppColors.primaryLight,
                  ],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.open_in_new_rounded,
                        color: Colors.white,
                        size: 16.rx(isDesktop),
                      ),
                      SizedBox(width: 6.rw(isDesktop)),
                      Text(
                        "Select Content & Send",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13.rx(isDesktop),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        // If simple mode (Centered around the Orbit Radar)
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. TOP PANEL: Sleek glassmorphic capsule for status and folder
            DaphqCard(
              isDesktop: isDesktop,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.isReceiving
                              ? "Discoverable as ${state.deviceName}"
                              : "Offline (${state.deviceName})",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.rx(isDesktop),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4.rh(isDesktop)),
                        GestureDetector(
                          onTap: state.isTransferring
                              ? null
                              : () async {
                                  String? path =
                                      await FilePicker.getDirectoryPath();
                                  if (path != null && mounted) {
                                    cubit.setReceiveFolder(path);
                                  }
                                },
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_open_rounded,
                                color: AppColors.primary,
                                size: 12.rx(isDesktop),
                              ),
                              SizedBox(width: 4.rw(isDesktop)),
                              Expanded(
                                child: Text(
                                  state.receiveFolder == null
                                      ? "Select download folder"
                                      : "Saving to: ${p.basename(state.receiveFolder!)}", // Slimmed down for capsule view!
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11.rx(isDesktop),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: state.isReceiving,
                    activeThumbColor: Colors.white,
                    activeTrackColor: AppColors.primary.withAlpha(50),
                    inactiveThumbColor: Colors.white38,
                    inactiveTrackColor: Colors.white10,
                    onChanged: state.isTransferring
                        ? null
                        : (value) {
                            if (value) {
                              if (state.receiveFolder == null) {
                                CustomSnackBar.show(
                                  context,
                                  message: AppConstants.selectFolderFirst,
                                );
                                return;
                              }
                              cubit.startReceiver();
                            } else {
                              cubit.stopReceiver();
                            }
                          },
                  ),
                ],
              ),
            ),

            // Selection Banner if items are selected
            if (state.selectedPaths.isNotEmpty && !state.isTransferring) ...[
              SizedBox(height: 12.rh(isDesktop)),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 10.rw(isDesktop),
                  vertical: 6.rh(isDesktop),
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(8.rr(isDesktop)),
                  border: Border.all(color: AppColors.primary.withAlpha(50)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      color: AppColors.primary,
                      size: 16.rx(isDesktop),
                    ),
                    SizedBox(width: 8.rw(isDesktop)),
                    Expanded(
                      child: Text(
                        "${state.selectedPaths.length} items selected",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12.rx(isDesktop),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => cubit.clearSelection(),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8.rw(isDesktop),
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        "Clear",
                        style: TextStyle(
                          color: AppColors.danger,
                          fontSize: 11.rx(isDesktop),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // 2. CENTER RADAR: Expanded, beautiful centerpiece radar!
            SizedBox(height: 35.rh(isDesktop)),
            OrbitalRadar(
              isDesktop: isDesktop,
              size: 320.0, // Expanded Orbit center stage!
            ),
            SizedBox(height: 35.rh(isDesktop)),

            // 3. BOTTOM PANEL: Sleek glassmorphic bar for trigger & scanning text
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withAlpha(15),
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Small blinking scanner indicator
                        Container(
                          width: 6.rx(isDesktop),
                          height: 6.rx(isDesktop),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: state.isReceiving
                                ? AppColors.primary
                                : Colors.white30,
                            boxShadow: state.isReceiving
                                ? const [
                                    BoxShadow(
                                      color: AppColors.primary,
                                      blurRadius: 4,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          state.isReceiving
                              ? "SCANNING FOR PEERS"
                              : "RADAR OFFLINE",
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 10.rx(isDesktop),
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(width: 1, height: 12, color: Colors.white10),
                        const SizedBox(width: 12),
                        InkWell(
                          onTap: () => cubit.toggleAdvancedMode(),
                          borderRadius: BorderRadius.circular(4),
                          child: Row(
                            children: [
                              Icon(
                                Icons.settings_ethernet_rounded,
                                size: 13.rx(isDesktop),
                                color: AppColors.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                "MANUAL IP",
                                style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 10.rx(isDesktop),
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
