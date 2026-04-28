/// Application-wide constants for Turbo Transfer.
class AppConstants {
  AppConstants._();

  /// TCP port used for all file transfers.
  static const int transferPort = 9999;

  /// Default target IP address for the sender.
  static const String defaultTargetIp = '192.168.137.1';

  /// UI update interval during transfers (milliseconds).
  static const int speedUpdateIntervalMs = 500;

  /// Connection timeout when sender connects to receiver (seconds).
  static const int connectionTimeoutSeconds = 5;

  /// Authorization response timeout (minutes).
  static const int authTimeoutMinutes = 1;

  /// Desktop window default size.
  static const double windowWidth = 1100;
  static const double windowHeight = 700;

  /// Desktop window minimum size.
  static const double windowMinWidth = 450;
  static const double windowMinHeight = 600;
}
