import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/review_screen.dart';

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
}
