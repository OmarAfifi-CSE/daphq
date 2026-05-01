/// Application-wide constants for Daphq.
class AppConstants {
  AppConstants._();

  /// TCP port used for all file transfers.
  static const int transferPort = 62004;

  /// Global branding string.
  static const String appName = 'Daphq';

  /// GitHub API endpoint for release checking.
  static const String githubApiUrl = 'https://api.github.com/repos/OmarAfifi-CSE/daphq/releases/latest';

  /// Foreground Service ID.
  static const int foregroundServiceId = 100;

  /// Android Notification Channel Information.
  static const String notificationChannelId = 'transfer_channel';
  static const String notificationChannelName = 'Daphq Transfer Service';
  static const String notificationChannelDesc = 'Keeps background transfers alive.';

  /// Default target IP address for the sender.
  static const String defaultTargetIp = '192.168.137.1';

  /// Flush threshold for socket buffer (2 MB).
  static const int socketFlushThresholdBytes = 2 * 1024 * 1024;

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

  // --- UI Strings ---
  static const String receiverMode = 'Receiver Mode';
  static const String senderMode = 'Sender Mode';
  static const String noFolderSelected = 'No receive folder selected';
  static const String saveToPrefix = 'Save to: ';
  static const String stopReceiver = 'Stop Receiver';
  static const String startReceiver = 'Start Receiver Server';
  static const String selectFolderFirst = 'Please select a receive folder first!';
  static const String enterTargetIp = 'Please enter target IP!';
  
  static String saveTo(String path) => '$saveToPrefix$path';

  static const String receiverIpLabel = 'Receiver IP Address (e.g. 192.168.x.x)';
  static const String receiverIpHelper = 'Please update this to the exact Receiver IP';
  static const String sendFile = 'Send File';
  static const String sendFolder = 'Send Folder';
  static const String cancelTransfer = 'Cancel Transfer';

  // --- Dialog Strings ---
  static const String storagePermissionRequired = 'Storage access is required to send and receive files. Please enable it in Settings.';
  static const String notificationPermissionWarning = 'Notifications are permanently denied. Transfers may stop if the app is minimized without notifications.';
  static const String proceedAnyway = 'Proceed Anyway';
  static const String openSettings = 'Open Settings';
  static const String cancel = 'Cancel';

  // --- Instructions ---
  static const String instructionsTitle = 'How to use for Max Speed';
  static const String step1 = '1. Connect both devices to the same network (Wi-Fi or Hotspot).';
  static const String step2 = '2. For max speed, one device should open a 5GHz Hotspot and the other connect to it.';
  static const String step3 = "3. On the RECEIVER: Select a folder and click 'Start Receiver Server'.";
  static const String step4 = "4. On the SENDER: Enter the Receiver's IP Address and select what to send.";

  // --- Layout Constants ---
  static const double borderRadius = 15.0;
  static const double cardPadding = 12.0;
}
