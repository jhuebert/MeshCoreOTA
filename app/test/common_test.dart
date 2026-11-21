import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/theme.dart';
import 'package:meshcore_repeater_manager/widgets/common.dart';

void main() {
  test('formatAge uses one phrasing for every cached value', () {
    final now = DateTime.utc(2026, 11, 20, 12);
    expect(formatAge(now, now: now), 'just now');
    expect(
        formatAge(now.subtract(const Duration(minutes: 5)), now: now),
        '5 min ago');
    expect(
        formatAge(now.subtract(const Duration(hours: 3)), now: now),
        '3 h ago');
    expect(
        formatAge(now.subtract(const Duration(days: 2)), now: now), '2 d ago');
  });

  testWidgets('LastKnownLabel shows the age of a cached value', (tester) async {
    final at = DateTime.now().subtract(const Duration(minutes: 2));
    await tester.pumpWidget(MaterialApp(
        theme: OtaTheme.dark, home: LastKnownLabel(at)));
    expect(find.textContaining('Last known 2 min ago'), findsOneWidget);
  });

  testWidgets('ActivityTile shows one shape for every activity', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: OtaTheme.dark,
      home: Scaffold(
        body: ActivityTile(
          icon: Icons.tune,
          title: 'Settings',
          subtitle: 'Change settings',
          badge: 'Ready',
          onTap: () => taps++,
        ),
      ),
    ));
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Change settings'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    expect(taps, 1);
  });

  testWidgets('a locked tile uses the lock glyph', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: OtaTheme.dark,
      home: const Scaffold(
        body: ActivityTile(
          icon: Icons.tune,
          title: 'Filter',
          subtitle: 'Not on this node',
          badge: 'Locked',
          locked: true,
        ),
      ),
    ));
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.text('Locked'), findsOneWidget);
  });
}
