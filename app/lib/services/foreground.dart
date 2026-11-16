import 'dart:io' show Platform;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../main.dart' show transferServiceEntry;

/// Foreground service wrapper for the LoRa transfer. Keeps the process
/// alive while the screen is off; the work itself runs in the main isolate.
/// Android/iOS only — desktop runs the transfer in-process (keep the window
/// open).
class TransferForegroundService {
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  static Future<void> start(String notificationText) async {
    if (!supported) return;
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

  static Future<void> update(String text) async {
    if (!supported) return;
    try {
      await FlutterForegroundTask.updateService(notificationText: text);
    } catch (_) {
      // A notification update is cosmetic; never fail the transfer for it.
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // Sibling of start(): a service that never started must not throw here.
    }
  }
}
