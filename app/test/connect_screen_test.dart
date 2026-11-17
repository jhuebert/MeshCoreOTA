import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/connect_screen.dart';

import 'support.dart';

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets(
      'tapping Connect with a working companion moves straight to the '
      'repeater step', (tester) async {
    _bigView(tester);
    final app = AppState();
    app.tcpLinkFactory = (_, __) {
      final link = FakeDeviceLink();
      // Answer CMD_GET_CONTACTS with an empty list, like a fresh companion.
      link.frameHandler = (frame) {
        if (frame.isEmpty) return;
        if (frame[0] == cmdGetContacts) {
          link.simulatePush(
              Uint8List.fromList([respCodeEndOfContacts, 0, 0, 0, 0]));
        }
      };
      return link;
    };

    await tester.pumpWidget(wrap(app, const ConnectScreen()));
    await tester.pump();
    await tester.tap(find.text('Connect'));
    // The companion's push frames flow through the real event loop; let it
    // run, not the fake-async one.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(app.connectionPhase, ConnectionPhase.connected);
    // No second tap needed to reach the repeater list.
    expect(find.text('Pick a repeater'), findsOneWidget);
  });

  testWidgets('a failed connect stays put and shows the error', (tester) async {
    _bigView(tester);
    final app = AppState();
    app.tcpLinkFactory = (_, __) => FakeDeviceLink(connectFailures: 1);

    await tester.pumpWidget(wrap(app, const ConnectScreen()));
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(app.connectionPhase, ConnectionPhase.disconnected);
    expect(app.connectError, isNotNull);
    expect(find.text('Pick a repeater'), findsNothing);
    // The form is still there to retry.
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('desktop can switch from the TCP default to Bluetooth',
      (tester) async {
    _bigView(tester);
    final app = AppState();

    await tester.pumpWidget(wrap(app, const ConnectScreen()));
    await tester.pump();

    // TCP is the default off mobile, but the BLE option stays available on
    // the platforms where flutter_blue_plus has an implementation.
    expect(find.text('TCP companion'), findsOneWidget);
    await tester.tap(find.text('Bluetooth'));
    await tester.pump();

    expect(find.text('Pair with the companion'), findsOneWidget);
    expect(find.text('TCP companion'), findsNothing);
  });

  testWidgets('a connected user has exactly one forward action',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.connectionPhase = ConnectionPhase.connected;
    app.companionName = 'Fake companion';

    await tester.pumpWidget(wrap(app, const ConnectScreen()));
    await tester.pump();

    expect(find.textContaining('Continue — pick a repeater'), findsOneWidget);
    expect(find.text('Connect'), findsNothing); // form hidden when connected
    expect(find.widgetWithText(TextButton, 'Disconnect'), findsOneWidget);

    await tester.tap(find.textContaining('Continue — pick a repeater'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a repeater'), findsOneWidget);
  });
}
