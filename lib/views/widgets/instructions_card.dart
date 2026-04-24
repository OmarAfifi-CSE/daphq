import 'package:flutter/material.dart';
import '../../core/app_colors.dart';
import '../../core/responsive_utils.dart';

class InstructionsCard extends StatelessWidget {
  final bool isDesktop;

  const InstructionsCard({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(15.0.rw(isDesktop)),
      decoration: BoxDecoration(
        color: AppColors.infoBg,
        borderRadius: BorderRadius.circular(15.0.rr(isDesktop)),
        border: Border.all(color: AppColors.infoBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Colors.blueAccent,
                size: 24.0.rx(isDesktop),
              ),
              SizedBox(width: 10.0.rw(isDesktop)),
              Expanded(
                child: Text(
                  "How to use for Max Speed",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16.0.rx(isDesktop),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10.0.rh(isDesktop)),
          _stepText(
            "1. Connect both devices to the same network (Wi-Fi or Hotspot).",
          ),
          SizedBox(height: 5.0.rh(isDesktop)),
          _stepText(
            "2. For max speed, one device should open a 5GHz Hotspot and the other connect to it.",
          ),
          SizedBox(height: 5.0.rh(isDesktop)),
          _stepText(
            "3. On the RECEIVER: Select a folder and click 'Start Receiver Server'.",
          ),
          SizedBox(height: 5.0.rh(isDesktop)),
          _stepText(
            "4. On the SENDER: Enter the Receiver's IP Address and select what to send.",
          ),
        ],
      ),
    );
  }

  Widget _stepText(String text) {
    return Text(
      text,
      style: TextStyle(color: Colors.white70, fontSize: 13.0.rx(isDesktop)),
    );
  }
}
