import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_ota/widgets/wizard.dart';

void main() {
  testWidgets('the wizard bar names the step and shows progress',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Pick a repeater'),
          bottom: const WizardBar(step: 2, label: 'Pick the repeater'),
        ),
        body: const SizedBox(),
      ),
    ));

    expect(find.text('Step 2 of 7'), findsOneWidget);
    expect(find.text('Pick the repeater'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(2 / 7, 0.001));
  });

  testWidgets('the bar clamps out-of-range steps', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: WizardBar(step: 99, label: 'Done')),
    ));
    expect(find.text('Step 7 of 7'), findsOneWidget);
  });

  testWidgets('the footer explains a locked step and fires the action',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WizardFooter(
          label: 'Continue',
          onPressed: () => tapped = true,
          hint: 'Pick something first',
        ),
      ),
    ));

    expect(find.text('Pick something first'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    expect(tapped, isTrue);
  });

  testWidgets('a busy footer is disabled and shows a spinner', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WizardFooter(
          label: 'Working',
          busy: true,
          onPressed: () {},
        ),
      ),
    ));
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('the step list is the whole path', (tester) async {
    expect(WizardBar.steps.length, 7);
    expect(WizardBar.steps.first, 'Connect');
    expect(WizardBar.steps.last, 'Verify');
  });
}
