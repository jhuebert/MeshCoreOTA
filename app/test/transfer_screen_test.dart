import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/resume_screen.dart';
import 'package:meshcore_repeater_manager/screens/transfer_screen.dart';
import 'package:meshcore_repeater_manager/services/foreground.dart';
import 'package:meshcore_repeater_manager/widgets/common.dart';

import 'support.dart';

class _PausedAppState extends AppState {
  @override
  Future<void> runUpdate({required String version, ResumeRun? resume}) async {
    updatePhase = UpdatePhase.idle;
    throw const UpdatePausedException();
  }
}

class _ComparisonStoppedAppState extends AppState {
  @override
  Future<void> runUpdate({required String version, ResumeRun? resume}) async {
    updatePhase = UpdatePhase.idle;
    throw const UpdateComparisonCancelledException();
  }
}

class _CountingAppState extends AppState {
  int runCalls = 0;

  @override
  Future<void> runUpdate({required String version, ResumeRun? resume}) async {
    runCalls++;
  }
}

class _RefusingForegroundPlatform extends FlutterForegroundTaskPlatform {
  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      NotificationPermission.granted;

  @override
  Future<void> startService({
    required AndroidNotificationOptions androidNotificationOptions,
    required IOSNotificationOptions iosNotificationOptions,
    required ForegroundTaskOptions foregroundTaskOptions,
    int? serviceId,
    List<ForegroundServiceTypes>? serviceTypes,
    required String notificationTitle,
    required String notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {
    throw StateError('foreground denied');
  }
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

AppState _app() {
  final app = AppState();
  app.target = contact('riley');
  app.library = FakeLibrary();
  return app;
}

void main() {
  testWidgets('the progress line shows the measured rate and time left',
      (tester) async {
    _bigView(tester);
    final app = _app();
    app.updatePhase = UpdatePhase.transferring;
    app.progress = const TransferProgress(
      phase: TransferPhase.sending,
      opsApplied: 400,
      opsTotal: 1000,
      packetsSent: 400,
      literalBytesSent: 400 * 173,
      retries: 3,
      elapsed: Duration(seconds: 100),
    );

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();
    // Progress notifications also refresh the background notification copy.
    app.notifyListeners();
    await tester.pump();

    expect(find.textContaining('left at the current rate'), findsOneWidget);
    expect(find.textContaining('ops/s'), findsOneWidget);
    expect(find.text('Measuring the transfer rate…'), findsNothing);
  });

  testWidgets('the ETA waits for a cold rate before reporting', (tester) async {
    _bigView(tester);
    final app = _app();
    app.updatePhase = UpdatePhase.transferring;
    app.progress = const TransferProgress(
      phase: TransferPhase.sending,
      opsApplied: null,
      opsTotal: 1000,
      packetsSent: 2,
      literalBytesSent: 0,
      retries: 0,
      elapsed: Duration(seconds: 2),
    );

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();

    expect(find.text('Measuring the transfer rate…'), findsOneWidget);
    expect(find.textContaining('left at the current rate'), findsNothing);
  });

  testWidgets('the transfer screen shows comparison progress and a stop',
      (tester) async {
    _bigView(tester);
    final app = _CountingAppState()
      ..updatePhase = UpdatePhase.comparing
      ..compareProgress = const RemoteDiffProgress(
        queries: 12,
        rangesHashed: 12,
        bytesReused: 2 * 1024 * 1024,
        bytesToSend: 2048,
        shiftProbeBatches: 0,
      );
    app.target = contact('riley');
    app.log.add('[00:00:00] armed');

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();

    expect(find.text('COMPARING'), findsOneWidget);
    expect(find.textContaining('12 exchanges'), findsOneWidget);
    expect(find.text('Stop — nothing has been staged'), findsOneWidget);
  });

  testWidgets('an identical image stops before staging', (tester) async {
    _bigView(tester);
    final app = _app();
    app.updatePhase = UpdatePhase.upToDate;

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();

    expect(find.text('Already up to date'), findsOneWidget);
    expect(find.text('Back — choose another image'), findsOneWidget);
    await tester.tap(find.text('Back — choose another image'));
    await tester.pump();
  });

  testWidgets('a stopped comparison offers to compare again', (tester) async {
    _bigView(tester);
    final app = _ComparisonStoppedAppState();
    app.target = contact('riley');

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();
    await tester.pump();

    expect(find.text('Comparison stopped'), findsOneWidget);
    expect(find.text('Compare again'), findsOneWidget);
    await tester.tap(find.text('Compare again'));
    await tester.pump();
  });

  testWidgets('a resumed transfer offers Pause, not a discard', (tester) async {
    _bigView(tester);
    final app = _app();
    app.updatePhase = UpdatePhase.transferring;

    await tester.pumpWidget(wrap(app, const TransferScreen(resuming: true)));
    await tester.pump();

    expect(find.text('Pause — keep what was already uploaded'), findsOneWidget);
    expect(find.textContaining('staged image is discarded'), findsNothing);
  });

  testWidgets('pausing shows a recovery path, not an error', (tester) async {
    _bigView(tester);
    final app = _PausedAppState();
    app.target = contact('riley');

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();
    await tester.pump();

    expect(find.text('Update paused'), findsOneWidget);
    expect(find.text('Continue this update'), findsOneWidget);
    expect(find.byType(ErrorBanner), findsNothing);

    await tester.tap(find.text('Continue this update'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ResumeScreen), findsOneWidget);
  });

  testWidgets('a refused foreground service stops the update before arming',
      (tester) async {
    _bigView(tester);
    final app = _CountingAppState();
    app.target = contact('riley');

    FlutterForegroundTask.resetStatic();
    FlutterForegroundTask.skipServiceResponseCheck = true;
    FlutterForegroundTaskPlatform.instance = _RefusingForegroundPlatform();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'test',
        channelName: 'test',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
    TransferForegroundService.isSupported = () => true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('org.huebert.meshcorepeatermanager/screen'),
            (call) async => null);
    addTearDown(() {
      TransferForegroundService.isSupported = () => false;
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('org.huebert.meshcorepeatermanager/screen'),
              null);
      FlutterForegroundTask.resetStatic();
    });

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();
    await tester.pump();
    // Reset the foundation debug flag before the framework's invariant check.
    debugDefaultTargetPlatformOverride = null;

    expect(find.byType(ErrorBanner), findsOneWidget);
    expect(find.textContaining('could not keep running in the background'),
        findsOneWidget);
    expect(app.runCalls, 0);
  });

  testWidgets('a failed update offers a way back, not a dead cancel',
      (tester) async {
    _bigView(tester);
    final app = _app();
    app.updatePhase = UpdatePhase.failed;

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();

    expect(find.text('Back — nothing was applied'), findsOneWidget);
    expect(find.textContaining('Cancel'), findsNothing);
    await tester.tap(find.text('Back — nothing was applied'));
    await tester.pump();
  });

  testWidgets('a transferring update can be paused with an hour-level ETA',
      (tester) async {
    _bigView(tester);
    final app = _CountingAppState()
      ..updatePhase = UpdatePhase.transferring
      ..progress = const TransferProgress(
        phase: TransferPhase.sending,
        opsApplied: 100,
        opsTotal: 1000,
        packetsSent: 100,
        literalBytesSent: 100 * 173,
        retries: 0,
        elapsed: Duration(hours: 2),
      );
    app.target = contact('riley');

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();

    expect(find.textContaining('left at the current rate'), findsOneWidget);
    await tester.tap(find.text('Pause — keep what was already uploaded'));
    await tester.pump();
    expect(app.cancelRequested, isTrue);
  });

  testWidgets('commit and verification buttons navigate onward',
      (tester) async {
    _bigView(tester);
    final app = _CountingAppState();
    app.target = contact('riley');

    app.updatePhase = UpdatePhase.readyToApply;
    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();
    await tester.tap(find.text('Commit update — reboot into new firmware'));
    await tester.pump();
  });

  testWidgets('a finished transfer offers to see verification', (tester) async {
    _bigView(tester);
    final app = _CountingAppState()..updatePhase = UpdatePhase.done;
    app.target = contact('riley');

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();
    await tester.tap(find.text('See verification'));
    await tester.pump();
  });
}
