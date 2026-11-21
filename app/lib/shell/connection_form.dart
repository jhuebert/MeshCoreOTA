import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/ble_device_link.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// The one connection form, used by the wizard's Connect step and by the
/// shell's ConnectionSheet. Connecting is the only action; the caller decides
/// where to go once the link is up.
class ConnectionForm extends StatefulWidget {
  const ConnectionForm({super.key, required this.onConnected});

  final VoidCallback onConnected;

  @override
  State<ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends State<ConnectionForm> {
  static final supportsBle = Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux;

  bool _scanning = false;
  String? _scanError;
  List<ScanResult> _results = const [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '5000');
  bool _tcpMode = !Platform.isAndroid && !Platform.isIOS;

  @override
  void dispose() {
    _scanSub?.cancel();
    if (supportsBle && _scanning) {
      unawaited(FlutterBluePlus.stopScan().catchError((_) {}));
    }
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _scanError = null;
      _results = const [];
    });
    try {
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() => _results = results);
      });
      await FlutterBluePlus.startScan(
        withServices: [MeshCoreUuids.serviceGuid],
        timeout: const Duration(seconds: 15),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _scanError =
          'Bluetooth is not available here. Use TCP / Wi-Fi instead.');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(Future<void> Function() action) async {
    await action();
    if (!mounted) return;
    if (context.read<AppState>().connectionPhase != ConnectionPhase.connected) {
      return; // the error banner explains the failure
    }
    widget.onConnected();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.connectionPhase == ConnectionPhase.connected;
    final busy = app.connectionPhase == ConnectionPhase.connecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Transport'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<bool>(
            segments: <ButtonSegment<bool>>[
              if (supportsBle)
                const ButtonSegment(
                    value: false,
                    label: Text('Bluetooth'),
                    icon: Icon(Icons.bluetooth)),
              const ButtonSegment(
                  value: true,
                  label: Text('TCP / Wi-Fi'),
                  icon: Icon(Icons.wifi)),
            ],
            selected: {_tcpMode},
            onSelectionChanged: (s) => setState(() => _tcpMode = s.first),
          ),
        ),
        if (!connected)
          ...(_tcpMode ? _tcpCard(app, busy) : _bleCard(app, busy)),
        if (!connected && app.connectError != null)
          ErrorBanner(_friendlyError(app)),
        if (connected) ..._connectedCard(app),
      ],
    );
  }

  String _friendlyError(AppState app) {
    final raw = app.connectError ?? '';
    if (raw.startsWith('TCP')) {
      return 'No companion found there. Check the host and port, then try again.';
    }
    if (raw.startsWith('BLE')) {
      return 'Could not reach the companion by Bluetooth. Try again or use TCP.';
    }
    return raw;
  }

  List<Widget> _tcpCard(AppState app, bool busy) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.wifi, color: OtaTheme.accent),
                      SizedBox(width: 10),
                      Text('TCP companion',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The companion on this network, by host and port.',
                    style: TextStyle(
                        color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _hostController,
                          decoration: const InputDecoration(labelText: 'Host'),
                          autocorrect: false,
                          keyboardType: TextInputType.url,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _portController,
                          decoration: const InputDecoration(labelText: 'Port'),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () {
                            final host = _hostController.text.trim();
                            final port =
                                int.tryParse(_portController.text.trim()) ??
                                    5000;
                            if (host.isEmpty) return;
                            FocusScope.of(context).unfocus();
                            _connect(
                                () => app.connectTcp(host: host, port: port));
                          },
                    icon: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF1A1203)),
                          )
                        : const Icon(playIcon),
                    label: Text(busy ? 'Connecting…' : 'Connect'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];

  List<Widget> _bleCard(AppState app, bool busy) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.bluetooth_searching,
                          color: OtaTheme.accent),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('Pair with the companion',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      if (_scanning)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_scanError != null) ...[
                    Text(_scanError!,
                        style:
                            const TextStyle(color: OtaTheme.bad, fontSize: 12)),
                    const SizedBox(height: 8),
                  ],
                  if (_results.isEmpty && !_scanning)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'Nothing found yet. Tap Scan. The companion must be '
                        'powered and nearby.',
                        style: TextStyle(
                            color: OtaTheme.textMuted,
                            fontSize: 12,
                            height: 1.4),
                      ),
                    ),
                  for (final result in _results)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        backgroundColor: OtaTheme.surfaceHigh,
                        child: Icon(Icons.cell_tower,
                            color: OtaTheme.accent, size: 20),
                      ),
                      title: Text(bleCompanionDisplayName(result)),
                      subtitle: Text(result.device.remoteId.toString(),
                          style: const TextStyle(
                              color: OtaTheme.textMuted, fontSize: 11)),
                      trailing:
                          const Icon(Icons.link, color: OtaTheme.textMuted),
                      onTap: busy
                          ? null
                          : () {
                              FocusScope.of(context).unfocus();
                              _connect(() => app.connectBle(result.device));
                            },
                    ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _scanning ? null : _startScan,
                    icon: const Icon(Icons.search),
                    label: Text(_scanning ? 'Scanning…' : 'Scan'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];

  List<Widget> _connectedCard(AppState app) => [
        const SectionHeader('Connected'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle, color: OtaTheme.ok),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          app.companionName.isNotEmpty
                              ? app.companionName
                              : 'Companion',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton(
                        onPressed: app.disconnect,
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${app.contacts.length} contacts known to the companion.',
                    style: const TextStyle(
                        color: OtaTheme.textMuted, fontSize: 12),
                  ),
                  if (app.connection.lastEndpoint != null)
                    Text(
                      'Connected via ${app.connection.lastEndpoint}.',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 11),
                    ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: widget.onConnected,
                    icon: const Icon(nextIcon),
                    label: const Text('Continue'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
}
