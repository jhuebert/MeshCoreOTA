import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/wizard.dart';
import 'login_screen.dart';

/// Step 2: choose the node to update. The admin login is deliberately a
/// separate step — with a long contact list the password field sat below the
/// fold, and the key can be (and the pubkey tab makes it easy to) chosen
/// without one.
class TargetScreen extends StatefulWidget {
  const TargetScreen({super.key});

  @override
  State<TargetScreen> createState() => _TargetScreenState();
}

class _TargetScreenState extends State<TargetScreen> {
  bool _showAll = false;
  String _manualKey = '';
  final _manualController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final selected = app.target;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pick a repeater'),
          bottom: const TabBar(
            indicatorColor: OtaTheme.accent,
            tabs: [
              Tab(text: 'Repeaters'),
              Tab(text: 'Public key'),
            ],
          ),
        ),
        body: Column(
          children: [
            const WizardBar(step: 2, label: 'Pick the repeater'),
            Expanded(
              child: TabBarView(
                children: [
                  _buildRepeaterTab(app, selected),
                  _buildManualTab(app),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: WizardFooter(
          label: 'Next: sign in',
          icon: Icons.login,
          onPressed: selected == null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  ),
          hint: selected == null
              ? 'Choose a repeater above, or enter its public key.'
              : null,
        ),
      ),
    );
  }

  Widget _buildRepeaterTab(AppState app, Contact? selected) {
    final repeaters =
        app.contacts.where((c) => c.advType == advTypeRepeater).toList();
    final visible = _showAll ? app.contacts : repeaters;

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (visible.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'No repeater contacts on this companion yet. Advertise from the '
              'repeater (or wait for its periodic advert), or use the Public '
              'key tab.',
              style: TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
            ),
          ),
        ...visible.map(
          (c) => Card(
            color: _sameKey(selected, c) ? OtaTheme.surfaceHigh : null,
            child: ListTile(
              leading: Icon(
                c.advType == advTypeRepeater
                    ? Icons.cell_tower
                    : Icons.device_hub_outlined,
                color: OtaTheme.accent,
              ),
              title: Text(c.name.isNotEmpty ? c.name : '(unnamed)'),
              subtitle: Text(
                _pathLabel(c),
                style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
              ),
              trailing: _sameKey(selected, c)
                  ? const Icon(Icons.radio_button_checked,
                      color: OtaTheme.accent)
                  : null,
              onTap: () => app.selectTarget(c),
            ),
          ),
        ),
        if (repeaters.length != app.contacts.length)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton.icon(
              onPressed: () => setState(() => _showAll = !_showAll),
              icon: Icon(_showAll ? Icons.expand_less : Icons.expand_more),
              label:
                  Text(_showAll ? 'Show repeaters only' : 'Show all contacts'),
            ),
          ),
      ],
    );
  }

  Widget _buildManualTab(AppState app) {
    final selected = app.target;
    final valid = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(_manualKey);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Text(
            'Paste the repeater\'s public key (64 hex characters) for a node '
            'this companion does not know.',
            style: TextStyle(
                color: OtaTheme.textMuted, fontSize: 12, height: 1.45),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _manualController,
                    decoration: const InputDecoration(
                      labelText: 'Public key (64 hex chars)',
                      isDense: true,
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (value) => setState(() {
                      _manualKey =
                          value.trim().toLowerCase().replaceAll(' ', '');
                    }),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: !valid
                        ? null
                        : () {
                            app.addManualTarget(_manualKey,
                                name: 'manual node');
                            FocusScope.of(context).unfocus();
                          },
                    child: const Text('Use this node'),
                  ),
                  if (selected != null && !valid) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Selected: '
                      '${selected.name.isNotEmpty ? selected.name : '(unnamed)'}',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static bool _sameKey(Contact? a, Contact b) {
    if (a == null || a.publicKey.length != b.publicKey.length) return false;
    for (var i = 0; i < a.publicKey.length; i++) {
      if (a.publicKey[i] != b.publicKey[i]) return false;
    }
    return true;
  }

  String _pathLabel(Contact c) {
    if (!c.hasDirectRoute) return 'no saved route';
    final hops = c.outPathLen & 0x3F;
    if (hops == 0) return 'direct';
    return 'direct, $hops hop(s)';
  }
}
