import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:meshcore_ota/app_state.dart';
import 'package:meshcore_ota/main.dart';

void main() {
  testWidgets('connect screen renders the transport switch and BLE card',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MeshCoreOtaApp(),
      ),
    );
    expect(find.text('MeshCoreOTA'), findsWidgets);
    expect(find.text('BLE'), findsOneWidget);
    expect(find.text('TCP'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
  });
}
