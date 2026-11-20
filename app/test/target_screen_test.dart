import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/screens/target_screen.dart';

import 'support.dart';

void main() {
  testWidgets('repeaters and the manual key are separate tabs', (tester) async {
    final app = AppState();
    app.contacts = [
      contact('riley'),
      contact('harper', key: keyOf(2)),
      contact('chatty companion', advType: advTypeChat, key: keyOf(3)),
    ];

    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    expect(find.text('Repeaters'), findsOneWidget);
    expect(find.text('Public key'), findsOneWidget);
    expect(find.text('riley'), findsOneWidget);
    expect(find.text('harper'), findsOneWidget);
    expect(find.text('chatty companion'), findsNothing);

    // Nothing selected: the next step is locked with an explanation.
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(next.onPressed, isNull);
    expect(find.textContaining('Choose a repeater'), findsOneWidget);
  });

  testWidgets('the step bar sits in the app bar above the tabs',
      (tester) async {
    final app = AppState();
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    final wizard = find.text('Step 2 of 8');
    expect(wizard, findsOneWidget);
    expect(find.ancestor(of: wizard, matching: find.byType(AppBar)),
        findsOneWidget);
    expect(tester.getRect(wizard).bottom,
        lessThan(tester.getRect(find.text('Repeaters')).top));
  });

  testWidgets('selecting a repeater unlocks the next step', (tester) async {
    final app = AppState();
    app.contacts = [contact('riley')];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    await tester.tap(find.text('riley'));
    await tester.pump();

    expect(app.target?.name, 'riley');
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Sign in'),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('the manual tab accepts a 64-hex public key', (tester) async {
    final app = AppState();
    app.contacts = const [];

    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();
    await tester.tap(find.text('Public key'));
    await tester.pumpAndSettle();

    final key = 'ab' * 32;
    await tester.enterText(find.byType(TextField), key);
    await tester.pump();

    // Too short until 64 characters.
    final short = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Use this node'),
    );
    expect(short.onPressed, isNotNull); // 64 chars already entered

    await tester.tap(find.widgetWithText(OutlinedButton, 'Use this node'));
    await tester.pump();

    expect(app.target, isNotNull);
    expect(app.target!.publicKeyHex, key);
  });

  testWidgets('a short manual key cannot be used', (tester) async {
    final app = AppState();
    app.contacts = const [];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();
    await tester.tap(find.text('Public key'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'abcd');
    await tester.pump();

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Use this node'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('show all contacts reveals non-repeaters', (tester) async {
    final app = AppState();
    app.contacts = [
      contact('riley'),
      contact('chatty companion', advType: advTypeChat, key: keyOf(3)),
    ];
    await tester.pumpWidget(wrap(app, const TargetScreen()));
    await tester.pump();

    await tester.tap(find.text('Show all contacts'));
    await tester.pump();

    expect(find.text('chatty companion'), findsOneWidget);
    expect(find.text('Show repeaters only'), findsOneWidget);
  });
}

/// A distinct 32-byte key for a fixture contact.
List<int> keyOf(int seed) =>
    List<int>.generate(32, (i) => (seed * 31 + i) & 0xFF);
