import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/login_screen.dart';
import 'package:meshcore_ota/services/radio_plan.dart';

import 'support.dart';

AppState _app() {
  final app = AppState();
  app.target = contact('riley');
  // The screen opens the library and refreshes the catalog on the first
  // frame; give it both so a widget test never asks a platform plugin or the
  // network for them.
  app.library = FakeLibrary();
  app.catalog = catalog([
    release('filter-v1.1.0-rc5', images: [
      asset('Xiao_S3_WIO_repeater_observer', 'v1.1.0-rc5-cd72e1a2'),
    ]),
  ]);
  return app;
}

void main() {
  testWidgets('password is optional and the check button is always offered',
      (tester) async {
    final app = _app();
    await tester.pumpWidget(wrap(app, const LoginScreen()));
    await tester.pump();

    expect(find.text('Admin password (optional)'), findsOneWidget);
    expect(find.textContaining('repeater ACL'), findsOneWidget);

    final check = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Check node'),
    );
    expect(check.onPressed, isNotNull); // a blank password is a valid login
  });

  testWidgets('shows the node facts the picker will be scoped to',
      (tester) async {
    final app = _app();
    app.adminPassword = '';
    app.nodeStatus = nodeStatus();
    app.nodeInfo = nodeInfo();
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    app.radio2Enabled = true;

    await tester.pumpWidget(wrap(app, const LoginScreen()));
    await tester.pump();

    expect(find.text('Xiao_S3_WIO_repeater_observer'), findsOneWidget);
    expect(find.text('0xba7783f9'), findsOneWidget);
    expect(find.text('enabled'), findsOneWidget);
    expect(find.textContaining('v1.1.0-rc5'), findsWidgets);

    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Next: choose firmware'),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('a blank password logs in and enables the next step',
      (tester) async {
    final app = _app();
    app.nodeStatus = nodeStatus();
    await tester.pumpWidget(wrap(app, const LoginScreen()));
    await tester.pump();

    expect(app.adminPassword, '');
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Next: choose firmware'),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('an unknown build suggests picking the board next',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _app();
    app.nodeStatus = nodeStatus();
    app.nodeInfo = nodeInfo(targetId: 0x11112222);

    await tester.pumpWidget(wrap(app, const LoginScreen()));
    await tester.pump();

    expect(find.textContaining('custom build'), findsOneWidget);
    expect(find.textContaining('not in the firmware catalog'), findsOneWidget);
  });

  testWidgets('next stays locked until the node has been checked',
      (tester) async {
    final app = _app();
    await tester.pumpWidget(wrap(app, const LoginScreen()));
    await tester.pump();

    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Next: choose firmware'),
    );
    expect(next.onPressed, isNull);
    expect(find.textContaining('Check the node first'), findsOneWidget);
  });

  testWidgets('the login helper updates the session password', (tester) async {
    final app = _app();
    await tester.pumpWidget(wrap(app, const LoginScreen()));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pump();
    expect(app.adminPassword, 'hunter2');
  });
}
