import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/firmware_screen.dart';

import 'support.dart';

const _board = 'Xiao_S3_WIO_repeater_observer';
final _targetId = targetIdForEnvironment(_board);

AppState _app() {
  final app = AppState();
  app.library = FakeLibrary();
  // Catalog: one stable release with two boards, one dev release.
  app.catalog = catalog([
    release('filter-v1.1.0-rc5', images: [
      asset(_board, 'v1.1.0-rc5-cd72e1a2', size: 1024),
      asset('RAK_4631_repeater', 'v1.1.0-rc5-aaaaaaa', size: 1024),
    ]),
    release('filter-v1.1.0-dev.9', images: [
      asset(_board, 'v1.1.0-dev.9-bbbbbbb', size: 1024),
    ]),
  ]);
  app.nodeInfo = nodeInfo(targetId: _targetId);
  app.selectedBoard = _board;
  return app;
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the picker is scoped to the node board', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.text('Detected from the node: $_board'), findsOneWidget);
    expect(find.text(_board), findsWidgets);
    expect(find.text('RAK_4631_repeater'), findsNothing);
    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget);
  });

  testWidgets('stable and dev are separate, newest-first tabs', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget);
    expect(find.text('filter-v1.1.0-dev.9'), findsNothing);

    await tester.tap(find.text('Dev builds'));
    await tester.pump();

    expect(find.text('filter-v1.1.0-dev.9'), findsOneWidget);
    expect(find.text('filter-v1.1.0-rc5'), findsNothing);
  });

  testWidgets('going offline never browses GitHub', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    await tester.tap(find.byTooltip('Go offline — never contact GitHub'));
    await tester.pump();

    expect(app.offlineMode, isTrue);
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('filter-v1.1.0-rc5'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Go online'));
    await tester.pump();
    expect(app.offlineMode, isFalse);
    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget);
  });

  testWidgets('the offline tab lists downloaded versions, not devices',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 1)),
        env: _board,
        version: 'v1.1.0-rc5-cd72e1a2',
        fileName: '$_board-v1.1.0-rc5-cd72e1a2-filter-abc1234.bin');
    lib.addImage(Uint8List.fromList(List.filled(64, 2)),
        env: 'RAK_4631_repeater',
        version: 'v1.1.0-rc5-cd72e1a2',
        fileName: 'RAK_4631_repeater-v1.1.0-rc5-aaaaaaa-filter-abc1234.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('Offline'));
    await tester.pumpAndSettle();

    expect(find.text('1 version(s) on this device · 0.0 MB'), findsOneWidget);
    expect(find.text('v1.1.0-rc5-cd72e1a2'), findsOneWidget);
    expect(find.text('2 image(s) · complete version'), findsOneWidget);

    await tester.tap(find.text('v1.1.0-rc5-cd72e1a2'));
    await tester.pumpAndSettle();
    expect(find.text(_board), findsOneWidget);
    expect(find.text('RAK_4631_repeater'), findsOneWidget);
  });

  testWidgets('selecting a downloaded image enables the review step',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    final entry = lib.addImage(Uint8List.fromList(List.filled(64, 3)),
        env: _board, version: 'v1.1.0-rc5-cd72e1a2');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(entry.fileName));
    await tester.pumpAndSettle();

    expect(app.selectedImage, isNotNull);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review update'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('a version already fully saved shows the saved state',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    for (final name in [
      '$_board-v1.1.0-rc5-cd72e1a2-filter-abc1234.bin',
      'RAK_4631_repeater-v1.1.0-rc5-aaaaaaa-filter-abc1234.bin',
    ]) {
      lib.addImage(Uint8List.fromList(List.filled(8, name.length)),
          env: _board, version: 'v1.1.0-rc5-cd72e1a2', fileName: name);
    }
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.byIcon(Icons.offline_pin), findsWidgets);
    final saved = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.offline_pin).first,
        matching: find.byType(IconButton),
      ),
    );
    expect(saved.onPressed, isNull);
  });
}
