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
      asset('RAK_4631_repeater', 'v1.1.0-rc5-cd72e1a2', size: 1024),
    ]),
    release('filter-v1.0.0-old', images: [
      asset('RAK_4631_repeater', 'v1.0.0-old', size: 1024),
    ]),
    release('filter-v1.1.0-dev.9', images: [
      asset(_board, 'v1.1.0-dev.9-bbbbbbb', size: 1024),
    ]),
  ]);
  app.nodeInfo = nodeInfo(targetId: _targetId);
  return app;
}

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the picker shows versions, not devices', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    // One row per version; the device names and the board dropdown are gone,
    // and the verbose explainer line is gone too.
    expect(find.textContaining('image for your board'), findsNothing);
    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget);
    expect(find.text('RAK_4631_repeater'), findsNothing);
    expect(find.text(_board), findsNothing);
    expect(find.text('All boards'), findsNothing);
    // Releases without an image for this board are hidden.
    expect(find.text('filter-v1.0.0-old'), findsNothing);
  });

  testWidgets('tapping a version selects the image for the node board',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 3)),
        env: _board,
        version: 'v1.1.0-rc5-cd72e1a2',
        fileName: '$_board-v1.1.0-rc5-cd72e1a2-filter-abc1234.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.text('filter-v1.1.0-rc5'));
    await tester.pumpAndSettle();

    expect(app.selectedAsset?.env, _board);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review update'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('stable and dev are separate, newest-first tabs', (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget);
    expect(find.text('filter-v1.1.0-dev.9'), findsNothing);

    await tester.tap(find.text('Dev'));
    await tester.pump();

    expect(find.text('filter-v1.1.0-dev.9'), findsOneWidget);
    expect(find.text('filter-v1.1.0-rc5'), findsNothing);
  });

  testWidgets('going offline shows only the versions this device holds',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 1)),
        env: _board,
        version: 'v1.1.0-rc5-cd72e1a2',
        fileName: '$_board-v1.1.0-rc5-cd72e1a2-filter-abc1234.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    await tester.tap(find.byTooltip('Go offline — never contact GitHub'));
    await tester.pumpAndSettle();

    expect(app.offlineMode, isTrue);
    expect(find.text('Offline'), findsNothing); // the Offline tab is gone
    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget); // saved → shown
    expect(find.text('filter-v1.1.0-dev.9'), findsNothing); // not saved
    expect(find.textContaining('saved for offline use'), findsNothing);

    // Toggle back online from the same button.
    await tester.tap(find.byTooltip('Offline — showing downloaded versions '
        'only. Tap to go online.'));
    await tester.pumpAndSettle();
    expect(app.offlineMode, isFalse);
  });

  testWidgets('offline with nothing saved shows the empty state',
      (tester) async {
    _bigView(tester);
    final app = _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    await tester.tap(find.byTooltip('Go offline — never contact GitHub'));
    await tester.pumpAndSettle();

    expect(find.text('No versions saved for offline use yet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Go online'));
    await tester.pumpAndSettle();
    expect(app.offlineMode, isFalse);
    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget);
  });

  testWidgets('in offline mode a downloaded version is one row',
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
        fileName: 'RAK_4631_repeater-v1.1.0-rc5-cd72e1a2-filter-abc1234.bin');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline — never contact GitHub'));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 version(s) on this device'), findsOneWidget);
    expect(find.text('filter-v1.1.0-rc5'), findsOneWidget);
    expect(find.textContaining('saved for offline use'), findsNothing);
    expect(find.text('RAK_4631_repeater'), findsNothing);

    // Tapping it picks the image built for this node's board.
    await tester.tap(find.text('filter-v1.1.0-rc5'));
    await tester.pumpAndSettle();
    expect(app.selectedLibraryEntry?.env, _board);
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review update'),
    );
    expect(review.onPressed, isNotNull);
  });

  testWidgets('selecting a downloaded image enables the review step',
      (tester) async {
    _bigView(tester);
    final app = _app();
    final lib = app.library as FakeLibrary;
    lib.addImage(Uint8List.fromList(List.filled(64, 3)),
        env: _board, version: 'v1.1.0-rc5-cd72e1a2');
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();
    await tester.tap(find.byTooltip('Go offline — never contact GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('filter-v1.1.0-rc5'));
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
      'RAK_4631_repeater-v1.1.0-rc5-cd72e1a2-filter-abc1234.bin',
    ]) {
      lib.addImage(Uint8List.fromList(List.filled(8, name.length)),
          env: _board, version: 'v1.1.0-rc5-cd72e1a2', fileName: name);
    }
    app.libraryEntries = await lib.list();

    await tester.pumpWidget(wrap(app, const FirmwareScreen()));
    await tester.pump();

    expect(find.byIcon(Icons.cloud_done), findsWidgets);
    final saved = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.cloud_done).first,
        matching: find.byType(IconButton),
      ),
    );
    expect(saved.onPressed, isNull);
  });
}
