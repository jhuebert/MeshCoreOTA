import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_repeater_manager/widgets/wizard.dart';

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

    expect(find.text('Step 2 of 8'), findsOneWidget);
    expect(find.text('Pick the repeater'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(2 / 8, 0.001));
  });

  testWidgets('tabbed steps put progress above the tabs under the title',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Pick a repeater'),
            bottom: const WizardTabBar(
              step: 2,
              label: 'Pick the repeater',
              tabs: [Tab(text: 'Repeaters'), Tab(text: 'Public key')],
            ),
          ),
          body: const TabBarView(children: [SizedBox(), SizedBox()]),
        ),
      ),
    ));

    final wizard = find.byType(WizardBar);
    final tabs = find.byType(TabBar);
    expect(wizard, findsOneWidget);
    expect(tabs, findsOneWidget);
    // Both live in the app bar, not in the body below the tabs.
    expect(find.ancestor(of: wizard, matching: find.byType(AppBar)),
        findsOneWidget);
    expect(
        find.ancestor(of: tabs, matching: find.byType(AppBar)), findsOneWidget);
    final wizardBox = tester.getRect(wizard);
    final tabBox = tester.getRect(tabs);
    expect(wizardBox.bottom, lessThanOrEqualTo(tabBox.top + 1));
    expect(
        tester
            .widget<WizardTabBar>(find.byType(WizardTabBar))
            .preferredSize
            .height,
        WizardBar.height + kTextTabBarHeight);
  });

  testWidgets('the bar clamps out-of-range steps', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: WizardBar(step: 99, label: 'Done')),
    ));
    expect(find.text('Step 8 of 8'), findsOneWidget);
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
    expect(WizardBar.steps.length, 8);
    expect(WizardBar.steps.first, 'Connect');
    expect(WizardBar.steps[4], 'Radio');
    expect(WizardBar.steps[5], 'Review');
    expect(WizardBar.steps.last, 'Verify');
  });
}
