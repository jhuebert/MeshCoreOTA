import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:device_link/device_link.dart';
import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/review_screen.dart';
import 'package:meshcore_ota/services/radio_plan.dart';
import 'package:ota_core/ota_core.dart';

import 'support.dart';

void main() {
  reviewSummaryTests();
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

AppState _app({RadioMode mode = RadioMode.liveMesh}) {
  final app = AppState();
  app.selectTarget(Contact(
    publicKey: Uint8List(32),
    name: 'target repeater',
    advType: advTypeRepeater,
  ));
  app.radioPlan = RadioPlan(
    mode: mode,
    preset: mode == RadioMode.liveMesh ? null : _preset,
  );
  app.remoteDiff = remoteDiff();
  return app;
}

const _board = 'Xiao_S3_WIO_repeater_observer';
final _targetId = targetIdForEnvironment(_board);
final _preset = LoRaPreset(
  frequencyHz: 913025000,
  bandwidthHz: 62500,
  spreadingFactor: 7,
  codingRate: 5,
);

/// A connected session over TCP, needed because the review screen's ETA row
/// only appears when the app has a link. The connect runs in real async time
/// (widget tests are fake-async otherwise).
Future<AppState> _connectedApp(WidgetTester tester,
    {RadioMode mode = RadioMode.tempRadio}) async {
  final app = AppState();
  app.tcpLinkFactory = (_, __) {
    final link = FakeDeviceLink();
    link.frameHandler = (frame) {
      if (frame.isEmpty) return;
      if (frame[0] == cmdGetContacts) {
        link.simulatePush(
            Uint8List.fromList([respCodeEndOfContacts, 0, 0, 0, 0]));
      }
    };
    return link;
  };
  await tester.runAsync(() => app.connectTcp(host: '127.0.0.1', port: 5000));
  app.selectTarget(Contact(
    publicKey: Uint8List(32),
    name: 'target repeater',
    advType: advTypeRepeater,
  ));
  app.radioPlan = RadioPlan(mode: mode, preset: _preset);
  app.remoteDiff = remoteDiff();
  return app;
}

void reviewSummaryTests() {
  testWidgets('the review lists companion, repeater and the image to send',
      (tester) async {
    _bigView(tester);
    final app = _app();
    app.companionName = 'test companion';
    app.transportKind = 'tcp';
    app.tcpHost = '10.0.0.8';
    app.tcpPort = 5000;
    app.nodeStatus = nodeStatus(running: 'v1.1.0-r3');
    app.nodeInfo = nodeInfo(targetId: _targetId);
    app.catalog = catalog([
      release('filter-v1.1.0-rc5', images: [
        asset(_board, 'v1.1.0-rc5-cd72e1a2'),
      ]),
    ]);
    final lib = FakeLibrary();
    app.library = lib;
    lib.addImage(Uint8List.fromList(List.filled(64, 7)),
        env: _board,
        version: 'v1.1.0-rc5-cd72e1a2',
        fileName: '$_board-v1.1.0-rc5-cd72e1a2-filter-abc1234.bin');
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(app.libraryEntries.single);
    app.remoteDiff = remoteDiff();

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.text('test companion'), findsOneWidget);
    expect(find.text('TCP — 10.0.0.8:5000'), findsOneWidget);
    expect(find.text('target repeater'), findsOneWidget);
    expect(find.text(_board), findsOneWidget); // the node's board
    expect(find.text('v1.1.0-r3'), findsOneWidget); // current firmware
    expect(find.text('v1.1.0-rc5-cd72e1a2'), findsOneWidget); // update to
    expect(find.text('Step 7 of 9'), findsOneWidget);
    // The step-5 comparison supplies the byte count shown here.
    expect(find.textContaining('Changes only — send'), findsOneWidget);
    // No navigation buttons and no base picker on this screen.
    expect(find.text('Choose base'), findsNothing);
    expect(find.text('Change image'), findsNothing);
    expect(find.text('What happens'), findsNothing);
    expect(find.text('SHA-256'), findsNothing);
  });

  testWidgets('a completed comparison lists what will be sent', (tester) async {
    _bigView(tester);
    final app = _app();
    app.nodeStatus = nodeStatus(running: 'v1.1.0-r3');
    app.remoteDiff = remoteDiff(literalBytes: 4096, copyBytes: 8);

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('Changes only — send'), findsOneWidget);
    expect(find.textContaining('of the image'), findsOneWidget);
    expect(find.textContaining('Matched against the running image'),
        findsOneWidget);
    expect(find.text('Step 7 of 9'), findsOneWidget);
  });

  testWidgets('a private radio plan is summarized, path override is not',
      (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.tempRadio);
    app.nodeStatus = nodeStatus(running: 'v1.1.0-r3');

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('Temporary private channel'), findsOneWidget);
    expect(find.textContaining('renews automatically'), findsOneWidget);
    expect(find.text('Direct path override (optional)'), findsNothing);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('a live-mesh plan shows the route and the warnings two',
      (tester) async {
    _bigView(tester);
    final app = _app();
    app.nodeStatus = nodeStatus(running: 'v1.1.0-r3');

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('Live mesh'), findsOneWidget);
    // The first board-mismatch warning bullet is gone, the other two stay.
    expect(find.textContaining('different board'), findsNothing);
    expect(find.textContaining('battery is low'), findsOneWidget);
    expect(find.textContaining('screen on'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets('an invalid radio plan disables start and says why',
      (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.radio2);
    // radio2 on the live frequency is refused.
    app.nodePreset = const LoRaPreset(
      frequencyHz: 913025000,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    app.radioPlan = RadioPlan(
      mode: RadioMode.radio2,
      preset: app.nodePreset,
    );

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('must not overlap'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('a same-image selection says the node is already up to date',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(
      Uint8List.fromList(List.filled(8, 9)),
      env: _board,
      version: 'v1.1.0-rc5-cd72e1a2',
    );
    app.libraryEntries = await lib.list();
    // The base matched to the node's running image IS this entry — this
    // image is what the node already runs.
    app.selectedLibraryEntry = entry;
    app.selectedAsset = null;
    app.remoteDiff =
        remoteDiff(upToDate: true, literalBytes: 0, copyBytes: 1449808);

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('already running this image'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Already up to date'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('a missing comparison keeps Start disabled', (tester) async {
    _bigView(tester);
    final app = _app();
    app.remoteDiff = null;

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('Comparing with the repeater'), findsOneWidget);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNull);
  });

  testWidgets('a nonzero delta keeps Start update enabled', (tester) async {
    _bigView(tester);
    final app = _app();
    app.remoteDiff = remoteDiff(literalBytes: 8, copyBytes: 100);

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('already running this image'), findsNothing);
    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start update'),
    );
    expect(start.onPressed, isNotNull);
  });

  testWidgets(
      'image sizes in MB and second-level ETAs are shown for small jobs',
      (tester) async {
    _bigView(tester);
    final app = await _connectedApp(tester);
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(
      Uint8List.fromList(List.filled(5000, 5)),
      env: _board,
      version: 'v1.1.0-rc5',
    );
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(entry);

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pumpAndSettle();

    expect(find.text('5 KB'), findsOneWidget);
    expect(find.text('~81s'), findsOneWidget);
  });

  testWidgets('minute-level ETAs are shown for typical images', (tester) async {
    _bigView(tester);
    final app = await _connectedApp(tester);
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(
      Uint8List.fromList(List.filled(120000, 6)),
      env: _board,
      version: 'v1.1.0-rc5',
    );
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(entry);

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pumpAndSettle();

    expect(find.text('~24 min'), findsOneWidget);
  });

  testWidgets('hour-level ETAs are shown for large images', (tester) async {
    _bigView(tester);
    final app = await _connectedApp(tester);
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(
      Uint8List.fromList(List.filled(1200000, 6)),
      env: _board,
      version: 'v1.1.0-rc5',
    );
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(entry);

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pumpAndSettle();

    expect(find.text('1.14 MB'), findsOneWidget);
    expect(find.text('~3.8 h'), findsOneWidget);
  });

  testWidgets('Start update opens the transfer step', (tester) async {
    _bigView(tester);
    final app = _app(mode: RadioMode.tempRadio);
    app.nodeStatus = nodeStatus(running: 'v1.1.0-r3');
    final lib = FakeLibrary();
    app.library = lib;
    final entry = lib.addImage(
      Uint8List.fromList(List.filled(5000, 5)),
      env: _board,
      version: 'v1.1.0-rc5',
    );
    app.libraryEntries = await lib.list();
    await app.selectLibraryEntryForUpdate(entry);
    app.remoteDiff = remoteDiff();

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Start update'));
    // TransferScreen animates indeterminately (progress unknown yet), so
    // settle with bounded pumps instead of pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Step 8 of 9'), findsOneWidget);
  });

  testWidgets('shifted matches are called out in the comparison summary',
      (tester) async {
    _bigView(tester);
    final app = _app();
    app.nodeStatus = nodeStatus(running: 'v1.1.0-r3');
    app.remoteDiff = remoteDiff(shiftProbeBatches: 3);

    await tester.pumpWidget(wrap(app, const ReviewScreen()));
    await tester.pump();

    expect(find.textContaining('including shifted matches'), findsOneWidget);
  });
}
