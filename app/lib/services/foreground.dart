import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../main.dart' show transferServiceEntry;

/// Foreground service wrapper for the LoRa transfer. Keeps the process
/// alive while the screen is off; the work itself runs in the main isolate.
class TransferForegroundService {
  static Future<void> start(String notificationText) async {
    final result = await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'MeshCoreOTA — firmware update',
      notificationText: notificationText,
      callback: transferServiceEntry,
    );
    if (result is ServiceRequestFailure) {
      // A missing notification permission or a denied foreground-service
      // grant must not silently kill the update; the screen shows the error.
      throw Exception('foreground service failed to start: ${result.error}');
    }
  }

  static Future<void> update(String text) =>
      FlutterForegroundTask.updateService(
        notificationText: text,
      );

  static Future<void> stop() => FlutterForegroundTask.stopService();
}
