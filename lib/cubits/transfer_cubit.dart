import 'package:flutter_bloc/flutter_bloc.dart';
import '../controllers/transfer_controller.dart';
import '../models/transfer_model.dart';
import 'transfer_state.dart';

class TransferCubit extends Cubit<TransferState> {
  final TransferController _controller = TransferController();

  TransferCubit() : super(TransferState(model: TransferModel()));

  void setReceiveFolder(String path) {
    emit(state.copyWith(receiveFolder: path));
  }

  void setTargetIp(String ip) {
    emit(state.copyWith(targetIp: ip));
  }

  void stopReceiver() {
    _controller.stopReceiver();
    emit(state.copyWith(
      isReceiving: false,
      isTransferring: false,
      model: TransferModel(status: "Receiver Stopped"),
    ));
  }

  Future<void> startReceiver() async {
    if (state.receiveFolder == null) return;

    emit(state.copyWith(isReceiving: true, isTransferring: true));

    _controller.startReceiver(
      saveDirectory: state.receiveFolder!,
      onUpdate: (model) {
        if (!isClosed) emit(state.copyWith(model: model));
      },
      onDone: () {
        // Keep receiver active unless user stops it
      },
    );
  }

  Future<void> sendData({required String path, required bool isFolder}) async {
    if (state.isTransferring || state.targetIp.trim().isEmpty) return;

    emit(state.copyWith(isTransferring: true));

    _controller.sendData(
      path: path,
      targetIp: state.targetIp.trim(),
      isFolder: isFolder,
      onUpdate: (model) {
        if (!isClosed) emit(state.copyWith(model: model));
      },
      onDone: () {
        if (!isClosed) emit(state.copyWith(isTransferring: false));
      },
    );
  }

  @override
  Future<void> close() {
    _controller.stopReceiver();
    return super.close();
  }
}
