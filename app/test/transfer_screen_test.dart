import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/transfer_screen.dart';

import 'support.dart';

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

  testWidgets('a failed update offers a way back, not a dead cancel',
      (tester) async {
    _bigView(tester);
    final app = _app();
    app.updatePhase = UpdatePhase.failed;

    await tester.pumpWidget(wrap(app, const TransferScreen()));
    await tester.pump();

    expect(find.text('Back — nothing was applied'), findsOneWidget);
    expect(find.textContaining('Cancel'), findsNothing);
  });
}
