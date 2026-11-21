import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// App-wide preferences and local data. No mesh traffic happens here.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SectionHeader('Firmware'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: SwitchListTile(
              title: const Text('Offline mode'),
              subtitle: const Text(
                'Never contact GitHub. Only saved versions are shown.',
              ),
              value: app.offlineMode,
              onChanged: app.setOfflineMode,
            ),
          ),
        ),
        const SectionHeader('Local data'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.history, color: OtaTheme.accent),
              title: const Text('Management history'),
              subtitle: Text(
                '${app.auditStore?.entries().length ?? 0} recent writes '
                'are kept on this device, with secrets removed.',
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            'The admin password is never saved. Firmware images and the '
            'offline setting stay on this device.',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}
