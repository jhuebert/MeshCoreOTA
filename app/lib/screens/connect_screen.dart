import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/ble_device_link.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'library_screen.dart';
import 'target_screen.dart';

/// Step 1: pick the companion the phone talks to. The companion is used as
/// a raw radio — the phone never speaks to the repeater directly.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  static final _supportsBle = Platform.isAndroid || Platform.isIOS;

  bool _scanning = false;
  String? _scanError;
  List<ScanResult> _results = const [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  final _hostController = TextEditingController(text: '127.0.0.1');
  final _portController = TextEditingController(text: '5000');
  // BLE on desktop is not supported by this app (BlueZ reliability); the
  // TCP companion is the Linux testing path.
  bool _tcpMode = !Platform.isAndroid && !Platform.isIOS;

  @override
  void dispose() {
    _scanSub?.cancel();
    if (_supportsBle) {
      unawaited(FlutterBluePlus.stopScan());
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
      setState(() => _scanning = false);
    } catch (e) {
      setState(() {
        _scanning = false;
        _scanError =
            'Could not start scanning — is Bluetooth on and are MeshCoreOTA’s '
            'Bluetooth permissions granted? ($e)';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final connected = app.connectionPhase == ConnectionPhase.connected;

    return Scaffold(
      appBar: AppBar(title: const Text('MeshCoreOTA')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 1, label: 'Connect the companion'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              'Update a MeshCore repeater over LoRa — no laptop at the site. '
              'This app talks to your companion device; the companion radios to '
              'the repeater.',
              style: TextStyle(
                  color: OtaTheme.textMuted, fontSize: 13, height: 1.45),
            ),
          ),
          const SectionHeader('Transport'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: false,
                    label: Text('Bluetooth'),
                    icon: Icon(Icons.bluetooth)),
                ButtonSegment(
                    value: true,
                    label: Text('TCP / Wi-Fi'),
                    icon: Icon(Icons.wifi)),
              ],
              selected: {_tcpMode},
              onSelectionChanged: (s) => setState(() => _tcpMode = s.first),
            ),
          ),
          if (_tcpMode)
            ..._buildTcpCard(context, app)
          else
            ..._buildBleCard(context, app),
          if (app.connectError != null) ErrorBanner(app.connectError!),
          if (connected) ..._buildConnectedCard(context, app),
          const SectionHeader('Firmware'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.inventory_2_outlined,
                    color: OtaTheme.accent),
                title: const Text('Firmware library'),
                subtitle: const Text(
                  'Download images ahead of time, import a custom build, or '
                  'prepare an offline field pack.',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                ),
                trailing:
                    const Icon(Icons.chevron_right, color: OtaTheme.textMuted),
                onTap: () async {
                  await app.refreshLibrary();
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LibraryScreen()),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBleCard(BuildContext context, AppState app) {
    return [
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
                      child: Text(
                        'Pair with the companion (NUS)',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
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
                      'No companions found yet — tap Scan. Your phone must be '
                      'within BLE range of the companion.',
                      style: TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
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
                    subtitle: Text(
                      result.device.remoteId.toString(),
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 11),
                    ),
                    trailing: const Icon(Icons.link, color: OtaTheme.textMuted),
                    onTap: app.connectionPhase == ConnectionPhase.connecting
                        ? null
                        : () {
                            FocusScope.of(context).unfocus();
                            app.connectBle(result.device);
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
  }

  List<Widget> _buildTcpCard(BuildContext context, AppState app) {
    return [
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
                    Text(
                      'TCP companion',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Point at a Wi-Fi or Ethernet companion (host:port), a USB '
                  'serial-to-TCP bridge, or a companion on this machine. This '
                  'is the normal path on a computer.',
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
                  onPressed: app.connectionPhase == ConnectionPhase.connecting
                      ? null
                      : () {
                          final host = _hostController.text.trim();
                          final port =
                              int.tryParse(_portController.text.trim()) ?? 5000;
                          if (host.isEmpty) return;
                          FocusScope.of(context).unfocus();
                          app.connectTcp(host: host, port: port);
                        },
                  icon: const Icon(Icons.link),
                  label: const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildConnectedCard(BuildContext context, AppState app) {
    return [
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
                      onPressed: () => app.disconnect(),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${app.contacts.length} contacts known to the companion.',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TargetScreen()),
                  ),
                  icon: const Icon(Icons.cell_tower),
                  label: const Text('Next: pick a repeater'),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}
