import 'package:flutter/material.dart';
import '../../core/app_colors.dart';
import '../../core/app_constants.dart';
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
                  AppConstants.instructionsTitle,
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
          _stepText(AppConstants.step1),
          SizedBox(height: 5.0.rh(isDesktop)),
          _stepText(AppConstants.step2),
          SizedBox(height: 5.0.rh(isDesktop)),
          _stepText(AppConstants.step3),
          SizedBox(height: 5.0.rh(isDesktop)),
          _stepText(AppConstants.step4),
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
