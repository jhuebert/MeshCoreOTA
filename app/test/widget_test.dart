import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/main.dart';

void main() {
  testWidgets('the app opens on the hub with a connection indicator',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MeshCoreRepeaterManagerApp(),
      ),
    );
    expect(find.text('Hub'), findsWidgets);
    expect(find.text('No companion connected'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('the connection sheet offers the shared connection form',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MeshCoreRepeaterManagerApp(),
      ),
    );
    await tester.tap(find.text('Connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('TCP companion'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('the library is a shell destination',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MeshCoreRepeaterManagerApp(),
      ),
    );
    await tester.tap(find.text('Library'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Firmware'), findsWidgets);
  });
}
