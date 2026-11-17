import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/firmware_screen.dart';

import 'support.dart';

const _board = 'Xiao_S3_WIO_repeater_observer';

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<AppState> _app() async {
  final app = AppState();
  final lib = FakeLibrary();
  // One downloaded (github) version, two boards.
  lib.addImage(Uint8List.fromList(List.filled(64, 1)),
      env: _board,
      version: 'v1.1.0-rc5',
      fileName: '$_board-v1.1.0-rc5-abc1234.bin');
  lib.addImage(Uint8List.fromList(List.filled(64, 2)),
      env: 'RAK_4631_repeater',
      version: 'v1.1.0-rc5',
      fileName: 'RAK_4631_repeater-v1.1.0-rc5-abc1234.bin');
  // One imported (custom) bin.
  lib.addImage(Uint8List.fromList(List.filled(64, 3)),
      env: 'custom',
      version: 'custom',
      fileName: 'my-build.bin',
      origin: 'import');
  app.library = lib;
  app.libraryEntries = await lib.list();
  app.catalog = catalog([
    release('filter-v1.1.0-rc5', images: [
      asset(_board, 'v1.1.0-rc5', size: 64),
      asset('RAK_4631_repeater', 'v1.1.0-rc5', size: 64),
    ]),
  ]);
  return app;
}

void main() {
  testWidgets('the standalone manager has no wizard chrome', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    expect(find.text('Firmware library'), findsOneWidget);
    expect(find.text('Choose the image'), findsNothing);
    expect(find.text('Review update'), findsNothing);
    // No node: the listing shows every board and says so.
    expect(find.textContaining('Not connected to a node'), findsOneWidget);
    // The offline switch is still there — downloading is the point here.
    expect(find.byTooltip('Go offline — never contact GitHub'), findsOneWidget);
  });

  testWidgets('downloaded versions and imported bins are separate tabs',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();

    // Offline tab: one row per version, holding both boards.
    await tester.tap(find.text('Offline'));
    await tester.pumpAndSettle();
    expect(find.text('v1.1.0-rc5'), findsOneWidget);
    expect(find.textContaining('2 image(s)'), findsOneWidget);
    expect(find.text('my-build.bin'), findsNothing);

    // Imported tab: one row per .bin.
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();
    expect(find.text('my-build.bin'), findsOneWidget);
    expect(find.textContaining('1 file(s)'), findsOneWidget);
    expect(find.text('v1.1.0-rc5'), findsNothing);
    expect(find.text('Import a .bin'), findsOneWidget);
  });

  testWidgets('imported files can be deleted, with confirmation',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete image?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(app.libraryEntries.length, 2);
    expect(app.importedEntries, isEmpty);
  });

  testWidgets('a whole version can be deleted from the Offline tab',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    // Simulate an update selected from the downloaded version, then delete it
    // underneath — the selection must be repaired, not left dangling.
    final entry = app.libraryEntries.firstWhere((e) => e.env == _board);
    await app.selectLibraryEntryForUpdate(entry);
    expect(app.selectedLibraryEntry, isNotNull);

    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    await tester.tap(find.text('Offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete this version'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Delete v1.1.0-rc5?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(app.offlineVersions, isEmpty);
    expect(app.libraryEntries.length, 1); // only the imported bin remains
    expect(app.selectedLibraryEntry, isNull);
    expect(app.selectedImage, isNull);
  });

  testWidgets('tapping a downloaded image inspects it instead of selecting',
      (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    await tester.tap(find.text('Offline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('v1.1.0-rc5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_board));
    await tester.pumpAndSettle();

    expect(app.selectedLibraryEntry, isNull); // no selection happened
    expect(find.text('SHA-256'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('no field-pack copy remains in the manager', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const FirmwareScreen(updateMode: false)));
    await tester.pump();
    expect(find.textContaining('field pack'), findsNothing);
  });
}
