import 'package:flutter/material.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'firmware_screen.dart';

/// Step 2: choose the node to update and prove the app can administer it.
class TargetScreen extends StatefulWidget {
  const TargetScreen({super.key});

  @override
  State<TargetScreen> createState() => _TargetScreenState();
}

class _TargetScreenState extends State<TargetScreen> {
  bool _showAll = false;
  String? _manualKey;
  final _manualController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final repeaters =
        app.contacts.where((c) => c.advType == advTypeRepeater).toList();
    final visible = _showAll ? app.contacts : repeaters;
    final selected = app.target;
    final status = app.nodeStatus;

    return Scaffold(
      appBar: AppBar(title: const Text('Pick a repeater')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SectionHeader('Target node'),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'No repeater contacts on this companion yet. Advertise from the '
                'repeater (or wait for its periodic advert), or enter its public '
                'key below.',
                style: TextStyle(
                    color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
              ),
            ),
          ...visible.map(
            (c) => Card(
              color: identical(selected, c) ? OtaTheme.surfaceHigh : null,
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
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                ),
                trailing: selected == c
                    ? const Icon(Icons.radio_button_checked,
                        color: OtaTheme.accent)
                    : null,
                onTap: () {
                  setState(() {
                    _manualKey = null;
                  });
                  app.selectTarget(c);
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextButton.icon(
              onPressed: () => setState(() => _showAll = !_showAll),
              icon: Icon(_showAll ? Icons.expand_less : Icons.expand_more),
              label:
                  Text(_showAll ? 'Show repeaters only' : 'Show all contacts'),
            ),
          ),
          const SectionHeader('Manual pubkey'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Paste the repeater\'s 32-byte public key (hex) for a node '
                      'this companion does not know.',
                      style: TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _manualController,
                      decoration: const InputDecoration(
                        labelText: 'Public key (64 hex chars)',
                        isDense: true,
                      ),
                      autocorrect: false,
                      onChanged: (value) {
                        setState(() {
                          _manualKey = value.trim().toLowerCase();
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: (_manualKey?.length ?? 0) != 64
                          ? null
                          : () {
                              app.addManualTarget(_manualKey!,
                                  name: 'manual node');
                              FocusScope.of(context).unfocus();
                            },
                      child: const Text('Use this node'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (selected != null) ...[
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
                        'Sign in to ${selected.name.isNotEmpty ? selected.name : 'the node'} '
                        'as admin to prove it runs the OTA firmware.',
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Admin password',
                          isDense: true,
                        ),
                        onChanged: (v) => app.adminPassword = v,
                        onSubmitted: (_) => app.probe(),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: app.probing || app.adminPassword.isEmpty
                            ? null
                            : () {
                                FocusScope.of(context).unfocus();
                                app.probe();
                              },
                        icon: app.probing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.login),
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
                      if (!status.ok)
                        InfoRow(
                            label: 'Last error',
                            value: 'err=${status.err}',
                            mono: false),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FirmwareScreen()),
                  ),
                  icon: const Icon(Icons.memory),
                  label: const Text('Choose firmware'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _pathLabel(Contact c) {
    if (!c.hasDirectRoute) return 'no direct route known — zero-hop only';
    final hops = c.outPathLen & 0x3F;
    if (hops == 0) return 'direct, zero hop';
    return 'direct, $hops hop(s) — path known';
  }
}
