class TransferModel {
  double speed; // MB/s
  double transferred; // MB
  double totalSize; // MB
  String fileName;
  String status;
  String? avgSpeed;
  String? totalTime;
  double progress;

  /// Non-null only during the analyze phase (before the transfer starts).
  /// When set, the UI replaces the speed display with a file-count indicator.
  int? analyzeCount;

  TransferModel({
    this.speed = 0.0,
    this.transferred = 0.0,
    this.totalSize = 0.0,
    this.fileName = "",
    this.status = "Idle",
    this.avgSpeed,
    this.totalTime,
    this.progress = 0.0,
    this.analyzeCount,
  });
}

/// Machine-readable lifecycle of a receiver-side transfer (plan T-002).
///
/// Populated by [ReceiverController] at each control-flow boundary so the
/// cubit no longer infers state from human-readable status strings.
enum TransferPhase {
  idle,
  receiving,
  finalizing,
  done,
  cancelled,
  failed,
}
