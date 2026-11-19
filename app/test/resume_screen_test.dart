import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/connect_screen.dart';
import 'package:meshcore_ota/screens/firmware_screen.dart';
import 'package:meshcore_ota/screens/resume_screen.dart';
import 'package:meshcore_ota/screens/transfer_screen.dart';
import 'package:meshcore_ota/services/radio_plan.dart';
import 'package:meshcore_ota/services/resume_store.dart';
import 'package:ota_core/ota_core.dart';

import 'support.dart';

ResumePlan _plan() => ResumePlan(
      createdAt: 1,
      targetPublicKeyHex: '00',
      targetName: 'XiaoS3 Repeater',
      imageSha256: '11',
      imageSize: 1000,
      version: 'v1.18.0-r4',
      targetId: 1,
      runningSha256: '22',
      frames: const <Uint8List>[],
      radioMode: RadioMode.liveMesh.index,
      radioPreset: null,
      radioDurationMinutes: 10,
      enabledRadio2ForUpdate: false,
      manualRoutePath: '',
      transportKind: 'tcp',
      tcpHost: '127.0.0.1',
      tcpPort: 5000,
      bleDeviceId: null,
    );

void main() {
  testWidgets('Connect shows an unfinished-update row and opens recovery',
      (tester) async {
    final app = AppState()..resumePlan = _plan();
    await tester.pumpWidget(wrap(app, const ConnectScreen()));

    expect(find.text('Unfinished update'), findsOneWidget);
    expect(find.textContaining('v1.18.0-r4'), findsWidgets);

    await tester.tap(find.text('Unfinished update'));
    // The sign-in state shows an indeterminate progress bar, so a full settle
    // would never finish. Two frames are enough for the route push.
    await tester.pump();
    await tester.pump();
    expect(find.byType(ResumeScreen), findsOneWidget);
    expect(find.text('Continue update'), findsWidgets);
  });

  testWidgets('Connect has no recovery row without a saved update',
      (tester) async {
    final app = AppState();
    await tester.pumpWidget(wrap(app, const ConnectScreen()));
    expect(find.text('Unfinished update'), findsNothing);
  });

  testWidgets('a resumable update offers Resume and shows real progress',
      (tester) async {
    final app = AppState()
      ..resumePlan = _plan()
      ..resumeCheck = ResumeCheck.ready
      ..resumeNextExpected = 7
      ..resumeStatus = const OtaStatus(
        running: 'v1.18.0',
        shaPrefix: 'caaed5f93630fb03',
        state: OtaPhase.staging,
        size: 1000,
        offset: 600,
        err: 0,
      );
    await tester.pumpWidget(wrap(app, const ResumeScreen()));

    expect(find.text('XiaoS3 Repeater'), findsOneWidget);
    expect(find.textContaining('60% of'), findsOneWidget);
    expect(find.text('Resume upload'), findsOneWidget);
    expect(find.text('Cancel resume — pick a different firmware instead'),
        findsOneWidget);
  });

  testWidgets('a finished upload offers Apply instead of Resume',
      (tester) async {
    final app = AppState()
      ..resumePlan = _plan()
      ..resumeCheck = ResumeCheck.readyToApply
      ..resumeStatus = const OtaStatus(
        running: 'v1.18.0',
        shaPrefix: 'caaed5f93630fb03',
        state: OtaPhase.ready,
        size: 1000,
        offset: 1000,
        err: 0,
      );
    await tester.pumpWidget(wrap(app, const ResumeScreen()));

    expect(find.text('Apply the finished update'), findsOneWidget);
    expect(find.text('Fully uploaded and checked — not applied yet'),
        findsOneWidget);
  });

  testWidgets('a lost session offers to pick a different firmware',
      (tester) async {
    final app = AppState()
      ..resumePlan = _plan()
      ..resumeCheck = ResumeCheck.unavailable
      ..resumeProblem = 'The repeater no longer holds the staged update.';
    await tester.pumpWidget(wrap(app, const ResumeScreen()));

    expect(find.text('Start a different update'), findsOneWidget);
    expect(find.textContaining('no longer holds'), findsOneWidget);
  });

  testWidgets('the sign-in prompt asks for the admin password again',
      (tester) async {
    final app = AppState()..resumePlan = _plan();
    await tester.pumpWidget(wrap(app, const ResumeScreen()));

    expect(find.text('Check the saved update'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('never saved'), findsOneWidget);
  });

  testWidgets('Resume opens the transfer step', (tester) async {
    final app = AppState()
      ..resumePlan = _plan()
      ..resumeCheck = ResumeCheck.ready
      ..resumeStatus = const OtaStatus(
        running: 'v1.18.0',
        shaPrefix: 'caaed5f93630fb03',
        state: OtaPhase.staging,
        size: 1000,
        offset: 600,
        err: 0,
      );
    await tester.pumpWidget(wrap(app, const ResumeScreen()));

    await tester.tap(find.text('Resume upload'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(TransferScreen), findsOneWidget);
  });

  testWidgets('Apply opens verification', (tester) async {
    final app = AppState()
      ..resumePlan = _plan()
      ..resumeCheck = ResumeCheck.readyToApply;
    await tester.pumpWidget(wrap(app, const ResumeScreen()));

    await tester.tap(find.text('Apply the finished update'));
    await tester.pump();
    await tester.pump();

    expect(app.updatePhase, UpdatePhase.readyToApply);
    expect(find.text('Verify'), findsWidgets);
  });

  testWidgets('Cancel discards the record and opens the firmware picker',
      (tester) async {
    final app = AppState()
      ..resumePlan = _plan()
      ..resumeCheck = ResumeCheck.ready
      ..offlineMode = true;
    await tester.pumpWidget(wrap(app, const ResumeScreen()));

    await tester
        .tap(find.text('Cancel resume — pick a different firmware instead'));
    await tester.pump();
    await tester.pump();

    expect(app.resumePlan, isNull);
    expect(find.byType(FirmwareScreen), findsOneWidget);
  });

  testWidgets('a stale record with no plan shows a clear message',
      (tester) async {
    await tester.pumpWidget(wrap(AppState(), const ResumeScreen()));
    expect(find.text('There is no interrupted update to continue.'),
        findsOneWidget);
  });
}
