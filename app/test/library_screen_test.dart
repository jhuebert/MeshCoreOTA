import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/library_screen.dart';

import 'support.dart';

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<AppState> _app() async {
  final app = AppState();
  final lib = FakeLibrary();
  lib.addImage(Uint8List.fromList(List.filled(64, 1)),
      env: 'Xiao_S3_WIO_repeater_observer', version: 'v1.1.0-rc5');
  lib.addImage(Uint8List.fromList(List.filled(64, 2)),
      env: 'RAK_4631_repeater', version: 'v1.1.0-rc4');
  app.library = lib;
  app.libraryEntries = await lib.list();
  return app;
}

void main() {
  testWidgets('lists the images and their metadata', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const LibraryScreen()));
    await tester.pump();

    expect(find.textContaining('2 image(s)'), findsOneWidget);
    expect(find.textContaining('Xiao_S3_WIO_repeater_observer'), findsWidgets);
    expect(find.text('Import a .bin firmware file'), findsOneWidget);
    expect(find.text('Import field pack (.zip)'), findsOneWidget);
    expect(find.text('Export field pack (.zip)'), findsOneWidget);
  });

  testWidgets('the menu selects an image for the update', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const LibraryScreen()));
    await tester.pump();

    final first = app.libraryEntries.first;
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use for the update'));
    await tester.pumpAndSettle();

    expect(app.selectedLibraryEntry?.id, first.id);
    expect(find.textContaining('Selected'), findsOneWidget);
  });

  testWidgets('the menu can make an image the delta base', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const LibraryScreen()));
    await tester.pump();

    final first = app.libraryEntries.first;
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use as delta base'));
    await tester.pumpAndSettle();

    expect(app.baseOverride?.id, first.id);
    expect(find.textContaining('Delta base set'), findsOneWidget);
  });

  testWidgets('deleting asks first and then removes the image', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const LibraryScreen()));
    await tester.pump();

    final first = app.libraryEntries.first;
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete image?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(app.libraryEntries.any((e) => e.id == first.id), isFalse);
    expect(app.libraryEntries, hasLength(1));
  });

  testWidgets('keep leaves the image alone', (tester) async {
    _bigView(tester);
    final app = await _app();
    await tester.pumpWidget(wrap(app, const LibraryScreen()));
    await tester.pump();

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Keep'));
    await tester.pumpAndSettle();

    expect(app.libraryEntries, hasLength(2));
  });
}
