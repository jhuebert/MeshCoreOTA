import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import '../shell/connection_form.dart';
import 'firmware_screen.dart';
import 'resume_screen.dart';
import 'target_screen.dart';

/// Step 1 of the update activity: pick the companion the phone talks to. The
/// companion is used as a raw radio, so the phone never speaks to the repeater
/// directly. The connection form is shared with the shell's ConnectionSheet.
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Repeater Manager')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 1, label: 'Connect the companion'),
          ConnectionForm(
            onConnected: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TargetScreen()),
            ),
          ),
          if (app.resumePlan != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Card(
                child: ListTile(
                  leading: const Icon(Icons.restore, color: OtaTheme.warn),
                  title: const Text('Unfinished update'),
                  subtitle: Text(
                    '${app.resumePlan!.targetName.isEmpty ? 'Repeater' : app.resumePlan!.targetName} '
                    '→ ${app.resumePlan!.version}. Continue without '
                    're-uploading what already arrived.',
                    style: const TextStyle(
                        color: OtaTheme.textMuted, fontSize: 11),
                  ),
                  trailing: const Icon(Icons.chevron_right,
                      color: OtaTheme.textMuted),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ResumeScreen()),
                  ),
                ),
              ),
            ),
          const SectionHeader('Firmware'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined,
                    color: OtaTheme.accent),
                title: const Text('Firmware library'),
                subtitle: const Text(
                  'Download versions for offline use, import a .bin, or '
                  'delete what you no longer need.',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                ),
                trailing:
                    const Icon(Icons.chevron_right, color: OtaTheme.textMuted),
                onTap: () async {
                  await app.refreshLibrary();
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) =>
                            const FirmwareScreen(updateMode: false)),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
