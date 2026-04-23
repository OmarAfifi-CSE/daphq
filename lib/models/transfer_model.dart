class TransferModel {
  double speed; // MB/s
  double transferred; // MB
  String fileName;
  String status;
  String? avgSpeed;
  String? totalTime;

  TransferModel({
    this.speed = 0.0,
    this.transferred = 0.0,
    this.fileName = "",
    this.status = "Idle",
    this.avgSpeed,
    this.totalTime,
  });
}
