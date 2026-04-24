import '../models/transfer_model.dart';

class TransferState {
  final TransferModel model;
  final bool isTransferring;
  final bool isReceiving;
  final String? receiveFolder;
  final String targetIp;

  TransferState({
    required this.model,
    this.isTransferring = false,
    this.isReceiving = false,
    this.receiveFolder,
    String? targetIp, // allow custom or fallback to a general base
  }) : targetIp = targetIp ?? "192.168.137.1";

  TransferState copyWith({
    TransferModel? model,
    bool? isTransferring,
    bool? isReceiving,
    String? receiveFolder,
    String? targetIp,
  }) {
    return TransferState(
      model: model ?? this.model,
      isTransferring: isTransferring ?? this.isTransferring,
      isReceiving: isReceiving ?? this.isReceiving,
      receiveFolder: receiveFolder ?? this.receiveFolder,
      targetIp: targetIp ?? this.targetIp,
    );
  }
}
