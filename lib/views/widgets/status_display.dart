import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../cubits/transfer_cubit.dart';
import '../../cubits/transfer_state.dart';
import '../../core/app_colors.dart';
import '../../core/responsive_utils.dart';

class StatusDisplay extends StatelessWidget {
  final bool isDesktop;

  const StatusDisplay({super.key, this.isDesktop = false});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TransferCubit, TransferState>(
      buildWhen: (previous, current) => previous.model != current.model,
      builder: (context, state) {
        final model = state.model;
        return Container(
          padding: EdgeInsets.all(25.0.rw(isDesktop)),
          decoration: BoxDecoration(
            color: AppColors.cardOverlay,
            borderRadius: BorderRadius.circular(25.0.rr(isDesktop)),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            children: [
              Text(
                model.status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontSize: 18.0.rx(isDesktop),
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 15.0.rh(isDesktop)),
              Text(
                "${model.speed.toStringAsFixed(1)} MB/s",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 50.0.rx(isDesktop),
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (model.avgSpeed != null)
                Padding(
                  padding: EdgeInsets.only(top: 10.0.rh(isDesktop)),
                  child: Text(
                    "Avg: ${model.avgSpeed} MB/s | Time: ${model.totalTime}s",
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 16.0.rx(isDesktop),
                    ),
                  ),
                ),
              Divider(color: Colors.white10, height: 40.0.rh(isDesktop)),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: _dataTile(
                      "Current File",
                      model.fileName.isEmpty ? "Ready" : model.fileName,
                      isFileName: true,
                    ),
                  ),
                  SizedBox(width: 15.0.rw(isDesktop)),
                  Expanded(
                    child: _dataTile(
                      "Data Size",
                      "${model.transferred.toStringAsFixed(1)} MB",
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _dataTile(String label, String val, {bool isFileName = false}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12.0.rx(isDesktop),
            ),
          ),
          SizedBox(height: 5.0.rh(isDesktop)),
          if (isFileName)
            Tooltip(
              message: val,
              child: Text(
                val,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14.0.rx(isDesktop),
                ),
              ),
            )
          else
            Text(
              val,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14.0.rx(isDesktop),
              ),
            ),
        ],
      );
}
