class TransferModel {
  double speed; // MB/s
  double transferred; // MB
  double totalSize; // MB
  String fileName;
  String status;
  String? avgSpeed;
  String? totalTime;
  double progress;

  /// Machine-readable phase of this transfer update (plan T-002).
  TransferPhase phase;

  /// Non-null only during the analyze phase (before the transfer starts).
  /// When set, the UI replaces the speed display with a file-count indicator.
  int? analyzeCount;

  /// Human-readable active transport route (e.g. `Direct 5GHz Wi-Fi` or `Router LAN`).
  String? routeLabel;

  TransferModel({
    this.speed = 0.0,
    this.transferred = 0.0,
    this.totalSize = 0.0,
    this.fileName = "",
    this.status = "Idle",
    this.avgSpeed,
    this.totalTime,
    this.progress = 0.0,
    this.phase = TransferPhase.idle,
    this.analyzeCount,
    this.routeLabel,
  });
}

/// Machine-readable lifecycle of a transfer (plan T-002).
///
/// Populated by [SenderController] and [ReceiverController] at each
/// control-flow boundary so the cubit and UI never infer state from
/// human-readable status strings.
enum TransferPhase {
  idle,
  analyzing,
  waitingAuth,
  sending,
  receiving,
  finalizing,
  done,
  cancelled,
  failed,
}
