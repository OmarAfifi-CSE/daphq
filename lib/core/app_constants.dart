/// Application-wide constants for Daphq.
class AppConstants {
  AppConstants._();

  /// TCP port used for all file transfers.
  static const int transferPort = 62004;

  /// Safe fallback TCP transfer ports (< 49152, outside Windows Hyper-V/WSL NAT ranges).
  static const List<int> transferFallbackPorts = <int>[42604, 42608];

  /// UDP port used for device discovery.
  static const int discoveryPort = 62005;

  /// Ordered UDP discovery ports: primary (62005) plus safe non-ephemeral fallbacks (< 49152).
  static const List<int> discoveryPorts = <int>[
    discoveryPort,
    42605,
    42606,
    42607,
  ];

  /// Global branding string.
  static const String appName = 'Daphq';

  /// GitHub API endpoint for release checking.
  static const String githubApiUrl = 'https://api.github.com/repos/OmarAfifi-CSE/daphq/releases/latest';

  /// Official Website URL for downloads and updates.
  static const String websiteUrl = 'https://omarafifi-cse.github.io/daphq/';

  /// Foreground Service ID.
  static const int foregroundServiceId = 100;

  /// Android Notification Channel Information.
  static const String notificationChannelId = 'transfer_channel';
  static const String notificationChannelName = 'Daphq Transfer Service';
  static const String notificationChannelDesc = 'Keeps background transfers alive.';

  /// Default target IP address for the sender.
  static const String defaultTargetIp = '192.168.137.1';

  /// Flush threshold for pipelined 5GHz socket writes (8 MB per stream).
  /// Large coalesced socket flushes fill high-bandwidth 5GHz/Wi-Fi 6 TCP windows
  /// without stalling real-time progress updates across parallel workers.
  static const int socketFlushThresholdBytes = 8 * 1024 * 1024;

  /// UI update interval during transfers (milliseconds).
  static const int speedUpdateIntervalMs = 500;

  /// Connection timeout when sender connects to receiver (seconds).
  static const int connectionTimeoutSeconds = 5;

  /// Active transfer timeout for socket operations (seconds).
  static const int transferTimeoutSeconds = 15;

  /// Authorization response timeout (minutes).
  static const int authTimeoutMinutes = 1;

  /// Discovery broadcast interval (seconds).
  static const int discoveryIntervalSeconds = 3;

  /// Desktop window default size.
  static const double windowWidth = 1100;
  static const double windowHeight = 700;

  /// Desktop window minimum size.
  static const double windowMinWidth = 450;
  static const double windowMinHeight = 600;

  // --- UI Strings ---
  static const String receiverMode = 'Receiver Mode';
  static const String senderMode = 'Sender Mode';
  static const String nearbyDevices = 'Nearby Devices';
  static const String searchingDevices = 'Searching for devices...';
  static const String noDevicesFound = 'No devices found yet. Make sure both are on same Wi-Fi.';
  static const String readyToReceive = 'Ready to Receive';
  static const String noFolderSelected = 'No receive folder selected';
  static const String saveToPrefix = 'Save to: ';
  static const String stopReceiver = 'Stop Receiver';
  static const String startReceiver = 'Start Receiver Server';
  static const String selectFolderFirst = 'Please select a receive folder first!';
  
  static String saveTo(String path) => '$saveToPrefix$path';

  static const String sendFile = 'Send File';
  static const String sendFolder = 'Send Folder';
  static const String cancelTransfer = 'Cancel Transfer';

  // --- Dialog Strings ---
  static const String storagePermissionRequired = 'Storage access is required to send and receive files. Please enable it in Settings.';
  static const String notificationPermissionWarning = 'Notifications are permanently denied. Transfers may stop if the app is minimized without notifications.';
  static const String proceedAnyway = 'Proceed Anyway';
  static const String openSettings = 'Open Settings';
  static const String cancel = 'Cancel';

  // --- Instructions & Info ---
  static const String infoTitle = 'Ready to Transfer?';
  static const String infoIntro = 'Follow these tips for a lightning-fast experience:';
  static const String infoStep1Title = 'Connect';
  static const String infoStep1Desc = 'Ensure both devices are on the same Wi-Fi or Hotspot.';
  static const String infoStep2Title = 'Discover';
  static const String infoStep2Desc = 'Devices appear automatically when "Start Receiver" is active.';
  static const String infoStep3Title = 'Send';
  static const String infoStep3Desc = 'Select a device, pick your files, and start the transfer.';
  static const String infoTip = 'Pro Tip: Use 5GHz Wi-Fi or Hotspot for lightning-fast speeds.';
  static const String gotIt = 'Got it';

  // --- Layout Constants ---
  static const double borderRadius = 15.0;
  static const double cardPadding = 12.0;

  // --- Discovery Status ---
  static const String discoveryConflictTitle = 'Network discovery is blocked';
  static const String discoveryConflictHowTo = 'How to fix this?';
  static const String discoveryConflictDesc =
      'Windows Firewall or another app is blocking device discovery on your network.';
  static const String discoveryConflictStep1 =
      '1. Allow Daphq on Private & Public networks in Windows Firewall.';
  static const String discoveryConflictStep2 =
      '2. If Windows Mobile Hotspot was just toggled, turn it OFF, wait 5 seconds, then turn it ON again.';
  static const String discoveryConflictStep3 =
      '3. Tap "Try Again Now" (Bluetooth discovery still works if enabled).';
  static const String discoveryConflictGotIt = 'Got it';
  static const String discoveryConflictTryAgain = 'Try Again Now';
  static const String discoveryStatusConnected = 'Connected';
  static const String discoveryStatusSearching = 'Searching for network...';
  static const String discoveryStatusNoConnection = 'No network connection';
}
