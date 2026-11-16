import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'firmware_screen.dart';

/// Step 3: prove the app may administer the node, and read its capabilities.
///
/// A password is optional. The repeater treats a blank login as "is this key
/// already in my ACL?", so a companion that is already an admin needs no
/// password at all — the field says so instead of refusing an empty value.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _password;

  @override
  void initState() {
    super.initState();
    _password =
        TextEditingController(text: context.read<AppState>().adminPassword);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      // Board detection needs the catalog's environment names; fetch it now
      // so the picker's board is already known on the next screen.
      if (app.catalog == null && !app.catalogLoading) app.loadCatalog();
      app.refreshLibrary();
    });
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.target;
    final status = app.nodeStatus;
    final board = app.detectedBoard;
    final radio2 = app.radio2Enabled;

    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 3, label: 'Admin access to the node'),
          const SectionHeader('Target'),
          InfoRow(
            label: 'Node',
            value: target == null
                ? '(none chosen)'
                : (target.name.isNotEmpty ? target.name : '(unnamed)'),
            mono: false,
          ),
          InfoRow(
            label: 'Admin',
            value: status == null
                ? 'not checked yet'
                : (status.running.isEmpty ? 'checked' : 'signed in'),
            mono: false,
          ),
          const SectionHeader('Admin login'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Sign in to '
                      '${target == null ? 'the node' : (target.name.isNotEmpty ? target.name : 'the node')} '
                      'to read its firmware state and allow an update.',
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Admin password (optional)',
                        isDense: true,
                        helperText:
                            'Leave blank when this companion key already has '
                            'admin rights in the repeater ACL.',
                        helperMaxLines: 2,
                      ),
                      onChanged: (v) => app.adminPassword = v,
                      onSubmitted: (_) => _check(app),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: app.probing || target == null
                          ? null
                          : () => _check(app),
                      icon: app.probing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_user_outlined),
                      label: Text(app.probing ? 'Checking…' : 'Check node'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (app.probeError != null) ErrorBanner(app.probeError!),
          if (status != null) ...[
            const SectionHeader('Node status'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Column(
                  children: [
                    InfoRow(label: 'Firmware', value: status.running),
                    InfoRow(label: 'State', value: status.state.name),
                    InfoRow(label: 'Running SHA', value: status.shaPrefix),
                    InfoRow(
                        label: 'Board',
                        value: board ??
                            (app.nodeInfo == null
                                ? 'unknown (no handshake)'
                                : 'custom build — pick a board on the next screen'),
                        mono: board != null),
                    if (app.nodeInfo != null)
                      InfoRow(
                        label: 'Target id',
                        value:
                            '0x${app.nodeInfo!.targetId.toRadixString(16).padLeft(8, '0')}',
                      ),
                    if (radio2 != null)
                      InfoRow(
                        label: 'radio2',
                        value: radio2 ? 'enabled' : 'off',
                        mono: false,
                      ),
                    if (!status.ok)
                      InfoRow(
                          label: 'Last error',
                          value: 'err=${status.err}',
                          mono: false),
                  ],
                ),
              ),
            ),
            if (board == null && app.nodeInfo != null)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'This build environment is not in the firmware catalog or '
                  'library. Pick its board on the next screen, or import the '
                  'image you want to install.',
                  style: TextStyle(
                      color: OtaTheme.warn, fontSize: 12, height: 1.45),
                ),
              ),
          ],
        ],
      ),
      bottomNavigationBar: WizardFooter(
        label: 'Next: choose firmware',
        icon: Icons.memory,
        onPressed: status == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FirmwareScreen()),
                ),
        hint: status == null
            ? 'Check the node first — the picker is scoped to its board.'
            : null,
      ),
    );
  }

  void _check(AppState app) {
    FocusScope.of(context).unfocus();
    app.probe();
  }
}
