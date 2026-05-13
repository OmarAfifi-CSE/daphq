import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../cubits/transfer_cubit.dart';
import '../../../cubits/transfer_state.dart';
import '../../../core/app_colors.dart';
import '../../../core/app_constants.dart';
import '../../../core/responsive_utils.dart';
import 'device_transfer_menu.dart';

class NearbyDevicesList extends StatelessWidget {
  final bool isDesktop;

  const NearbyDevicesList({super.key, required this.isDesktop});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        if (state.discoveredDevices.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 20.0.rh(isDesktop)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20.rx(isDesktop),
                    height: 20.rx(isDesktop),
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
                    ),
                  ),
                  SizedBox(height: 15.rh(isDesktop)),
                  Text(
                    AppConstants.searchingDevices,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13.rx(isDesktop),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: state.discoveredDevices.length,
          separatorBuilder: (context, index) => SizedBox(height: 10.rh(isDesktop)),
          itemBuilder: (context, index) {
            final device = state.discoveredDevices[index];
            return Container(
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(10),
                borderRadius: BorderRadius.circular(12.rr(isDesktop)),
                border: Border.all(color: Colors.white12),
              ),
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12.rw(isDesktop),
                  vertical: 4.rh(isDesktop),
                ),
                leading: Container(
                  padding: EdgeInsets.all(8.rr(isDesktop)),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _getDeviceIcon(device.name),
                    color: AppColors.primary,
                    size: 20.rx(isDesktop),
                  ),
                ),
                title: Text(
                  device.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15.rx(isDesktop),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                subtitle: Text(
                  device.ip,
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 11.rx(isDesktop),
                  ),
                ),
                trailing: Icon(
                  Icons.send_rounded,
                  color: AppColors.primary.withAlpha(150),
                  size: 18.rx(isDesktop),
                ),
                onTap: () => DeviceTransferMenu.show(context, device.ip, device.name, isDesktop),
              ),
            );
          },
        );
      },
    );
  }

  IconData _getDeviceIcon(String name) {
    name = name.toLowerCase();
    if (name.contains('phone') || name.contains('android') || name.contains('samsung') || name.contains('pixel')) {
      return Icons.phone_android;
    } else if (name.contains('pc') || name.contains('windows') || name.contains('laptop') || name.contains('desktop')) {
      return Icons.laptop;
    } else if (name.contains('ipad') || name.contains('tablet')) {
      return Icons.tablet_mac;
    }
    return Icons.devices;
  }
}
