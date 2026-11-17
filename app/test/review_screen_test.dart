import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/review_screen.dart';
import 'package:meshcore_ota/services/radio_plan.dart';
import 'package:ota_core/ota_core.dart';

import 'support.dart';

void main() {
  testWidgets('route override accepts valid paths and surfaces invalid ones',
      (tester) async {
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );

    expect(find.text('Direct path override (optional)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'c0ff');
    await tester.pump();
    expect(app.manualRoutePath, 'c0ff');
    expect(find.textContaining('direct override: c0ff'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'not-hex');
    await tester.pump();
    expect(app.manualRouteError, isNotNull);
    expect(find.textContaining('path'), findsWidgets);
  });

  reviewExtras();
}

// The review step is where the operator sees the radio choice and the
// before/after images. These cover the wizard chrome and the base picker.
void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void reviewExtras() {
  testWidgets(
      'Choose base is left of Change image and there is no offline switch',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Work offline'), findsNothing);
    final base = tester.getCenter(find.text('Choose base')).dx;
    final image = tester.getCenter(find.text('Change image')).dx;
    expect(base, lessThan(image));

    // Exercise the base picker sheet paths.
    await tester.tap(find.text('Choose base'));
    await tester.pumpAndSettle();
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('Full image'), findsOneWidget);
    await tester.tap(find.text('Full image'));
    await tester.pumpAndSettle();
    expect(app.forceFullImage, isTrue);
    await tester.tap(find.text('Choose base'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();
    expect(app.forceFullImage, isFalse);
  });

  testWidgets('a same-image selection says the node is already up to date',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));
    app.deltaResult =
        const DeltaResult(ops: [], literalBytes: 0, copyBytes: 1449808);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.textContaining('already running this image'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start update'), findsNothing);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Already up to date'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('the full-image override re-enables a same-image re-flash',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));
    app.deltaResult =
        const DeltaResult(ops: [], literalBytes: 0, copyBytes: 1449808);
    app.forceFullImage = true;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.textContaining('already running this image'), findsNothing);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('a nonzero delta keeps Start update enabled', (tester) async {
    _bigView(tester);
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));
    app.deltaResult =
        const DeltaResult(ops: [CopyOp(0, 8)], literalBytes: 8, copyBytes: 100);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.textContaining('already running this image'), findsNothing);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('a private radio plan replaces the path override',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    app.radioPlan = RadioPlan(
      mode: RadioMode.tempRadio,
      preset: RadioPlan.suggestTempRadio(app.nodePreset!),
      durationMinutes: 15,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Step 5 of 7'), findsOneWidget);
    expect(find.text('Temporary private channel'), findsOneWidget);
    expect(find.textContaining('15 min'), findsOneWidget);
    expect(find.text('Direct path override (optional)'), findsNothing);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('the base picker chooses a library image', (tester) async {
    _bigView(tester);
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(
      Uint8List.fromList(List.filled(8, 9)),
      env: 'Xiao_S3_WIO_repeater_observer',
      version: 'v1.1.0-rc5-cd72e1a2',
    );
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Choose base'));
    await tester.pumpAndSettle();
    expect(find.text('Delta base'), findsOneWidget);
    await tester.tap(find.text(entry.fileName));
    await tester.pumpAndSettle();

    expect(app.baseOverride?.id, entry.id);
    expect(find.textContaining('chosen manually'), findsOneWidget);
  });

  testWidgets('an invalid radio plan blocks the start button', (tester) async {
    _bigView(tester);
    final app = AppState();
    app.selectTarget(Contact(
      publicKey: Uint8List(32),
      name: 'target repeater',
      advType: advTypeRepeater,
    ));
    // radio2 on the live frequency is refused by the node.
    app.nodePreset = const LoRaPreset(
      frequencyHz: 910525000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    app.radioPlan = RadioPlan(
      mode: RadioMode.radio2,
      preset: app.nodePreset,
      durationMinutes: 10,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.textContaining('must not overlap'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNull);
  });
}
