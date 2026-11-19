import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/screens/compare_screen.dart';
import 'package:meshcore_ota/screens/radio_settings_screen.dart';
import 'package:meshcore_ota/screens/review_screen.dart';

import 'support.dart';

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('step 5 shows the comparison result and continues to radio',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.remoteDiff = remoteDiff(
      literalBytes: 59392,
      copyBytes: 1390432,
      queries: 37,
      shiftProbeBatches: 2,
    );

    await tester.pumpWidget(wrap(app, const CompareScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Step 5 of 9'), findsOneWidget);
    expect(find.textContaining('COMPARISON READY'), findsOneWidget);
    expect(find.text('37'), findsOneWidget); // exchanges
    expect(find.text('2'), findsOneWidget); // shifted matches
    expect(find.textContaining('Changed'), findsNothing);

    await tester.tap(find.text('Next: radio settings'));
    await tester.pumpAndSettle();
    expect(find.byType(RadioSettingsScreen), findsOneWidget);
  });

  testWidgets('an identical image stops the wizard at the comparison',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.remoteDiff = remoteDiff(upToDate: true, literalBytes: 0);

    await tester.pumpWidget(wrap(app, const CompareScreen()));
    await tester.pumpAndSettle();

    expect(
        find.textContaining('already runs exactly this image'), findsOneWidget);
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Go back to choose another image'),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('a failed comparison offers a retry and sends nothing',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.compareError = 'no answer from the node';

    await tester.pumpWidget(wrap(app, const CompareScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not compare'), findsOneWidget);
    expect(find.textContaining('Nothing has been sent'), findsOneWidget);
    expect(find.byType(ReviewScreen), findsNothing);
  });

  testWidgets('the in-progress view shows counts without a false percentage',
      (tester) async {
    _bigView(tester);
    final app = AppState();
    app.comparing = true;

    await tester.pumpWidget(wrap(app, const CompareScreen()));
    // Indeterminate spinner: settle with bounded pumps.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('COMPARING'), findsOneWidget);
    expect(find.text('Ranges checked'), findsOneWidget);
    expect(find.text('Exchanges'), findsOneWidget);
    expect(find.text('0'), findsWidgets);
    expect(find.textContaining('%'), findsNothing);
  });
}
