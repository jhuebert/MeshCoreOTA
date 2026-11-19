import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'screens/connect_screen.dart';
import 'theme.dart';

/// Entry point. The update pipeline is long-running (minutes over LoRa), so
/// the app starts a foreground service during the transfer to survive
/// screen-off; the stub callback below never runs (work stays in the main
/// isolate).
@pragma('vm:entry-point')
void transferServiceEntry() {}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'meshcore_ota_transfer',
      channelName: 'OTA firmware transfer',
      channelDescription:
          'Keeps the LoRa link and the firmware transfer alive while the screen is off.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
      // TCP companions are common here; keep the Wi-Fi on screen-off too.
      allowWifiLock: true,
    ),
  );
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..initServices(),
      child: const MeshCoreOtaApp(),
    ),
  );
}

class MeshCoreOtaApp extends StatelessWidget {
  const MeshCoreOtaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshCoreOTA',
      debugShowCheckedModeBanner: false,
      theme: OtaTheme.dark,
      home: const ConnectScreen(),
    );
  }
}
