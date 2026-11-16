import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/radio_settings_screen.dart';
import 'package:meshcore_ota/services/radio_plan.dart';

import 'support.dart';

const _live = LoRaPreset(
  frequencyHz: 910525000,
  bandwidthHz: 62500,
  spreadingFactor: 7,
  codingRate: 5,
);

AppState _app({RadioMode mode = RadioMode.tempRadio, bool? radio2}) {
  final app = AppState();
  app.nodePreset = _live;
  app.radio2Enabled = radio2;
  app.radioPlan = RadioPlan(
    mode: mode,
    preset: RadioPlan.suggestTempRadio(_live),
    durationMinutes: 10,
  );
  return app;
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('offers the three radios and explains the private preset',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(find.text('Live mesh'), findsOneWidget);
    expect(find.text('Temporary private channel'), findsOneWidget);
    expect(find.text('The repeater\'s second preset'), findsOneWidget);
    expect(find.text('PRIVATE PRESET'), findsOneWidget);
    expect(find.text('Keep the preset for (minutes)'), findsOneWidget);
  });

  testWidgets('an invalid preset is refused before saving', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '100');
    await tester.pump();

    expect(find.textContaining('frequency must be 150–2500'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use these settings'),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('suggest settings restores a valid preset', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '100');
    await tester.pump();
    await tester.tap(find.text('Suggest settings'));
    await tester.pump();

    expect(find.textContaining('frequency must be 150–2500'), findsNothing);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use these settings'),
    );
    expect(save.onPressed, isNotNull);
  });

  testWidgets('saving a private plan stores the preset and duration',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '914');
    await tester.enterText(
        find.widgetWithText(TextField, 'Keep the preset for (minutes)'), '25');
    await tester.pump();
    await tester.tap(find.text('Use these settings'));
    await tester.pump();

    expect(app.radioPlan.mode, RadioMode.tempRadio);
    expect(app.radioPlan.preset!.frequencyMhz, 914);
    expect(app.radioPlan.durationMinutes, 25);
  });

  testWidgets('switching to live mesh hides the private preset',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    await tester.tap(find.text('Live mesh'));
    await tester.pump();

    expect(find.text('PRIVATE PRESET'), findsNothing);
    await tester.tap(find.text('Use these settings'));
    await tester.pump();
    expect(app.radioPlan.mode, RadioMode.liveMesh);
  });

  testWidgets('each radio shows its own transfer estimate', (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(Uint8List.fromList(List.filled(120000, 3)),
        env: 'Xiao_S3_WIO_repeater_observer', version: 'v1.1.0-rc5');
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(entry);

    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    // Three mode tiles plus the duration card.
    expect(find.textContaining('Estimated transfer:'), findsNWidgets(4));
    expect(find.textContaining('\u00d7 the airtime'), findsOneWidget);
  });

  testWidgets('an existing radio2 configuration is called out', (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.radio2, radio2: true);
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    expect(find.textContaining('radio2 is already enabled'), findsOneWidget);
    expect(find.textContaining('will not change the node'), findsOneWidget);
  });

  testWidgets('radio2 must clear the live band', (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.radio2, radio2: false);
    await tester.pumpWidget(wrap(app, const RadioSettingsScreen()));
    await tester.pump();

    // Same frequency as the live preset: refused.
    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '910.525');
    await tester.pump();

    expect(find.textContaining('must not overlap'), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use these settings'),
    );
    expect(save.onPressed, isNull);
  });
}
