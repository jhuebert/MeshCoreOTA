import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'transfer_screen.dart';

/// Step 4: everything about the update before anything goes on air. The
/// app picks the parameters; the node only applies ops and verifies SHA-256.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final TextEditingController _routeController;

  @override
  void initState() {
    super.initState();
    _routeController =
        TextEditingController(text: context.read<AppState>().manualRoutePath);
  }

  @override
  void dispose() {
    _routeController.dispose();
    super.dispose();
  }

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String _fmtEta(int seconds) {
    if (seconds < 120) return '~${seconds}s at the current radio config';
    final minutes = (seconds / 60).ceil();
    return '~$minutes min at the current radio config';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.target!;
    final status = app.nodeStatus;
    final env = app.selectedEnvironment;
    final delta = app.deltaResult;
    final imageBytes = app.selectedImage?.length ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Review update')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const SectionHeader('Node'),
          InfoRow(
              label: 'Node',
              value: target.name.isNotEmpty ? target.name : '(unnamed)',
              mono: false),
          InfoRow(
            label: 'Route',
            value: app.manualRoutePath.trim().isNotEmpty
                ? 'direct override: ${app.manualRoutePath.trim()} (saved on the companion)'
                : (target.hasDirectRoute
                    ? ((target.outPathLen & 0x3F) == 0
                        ? 'direct, zero hop'
                        : 'direct, ${target.outPathLen & 0x3F} hop(s)')
                    : 'no saved route — requests flood'),
            mono: false,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _routeController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Direct path override (optional)',
                hintText: 'c0ff, c0c0  (“0” for zero-hop)',
                helperText:
                    'Comma-separated hash hops. Empty keeps the saved route; the '
                    'override is pushed to the companion (like change_path).',
                errorText: app.manualRouteError,
                border: const OutlineInputBorder(),
              ),
              onChanged: app.setManualRoutePath,
            ),
          ),
          InfoRow(label: 'Running', value: status?.running ?? '?'),
          const SectionHeader('Update'),
          InfoRow(label: 'Board', value: env ?? '?'),
          InfoRow(label: 'To version', value: app.selectedVersion ?? '?'),
          InfoRow(label: 'Image size', value: _fmtBytes(imageBytes)),
          InfoRow(
            label: 'Transfer',
            value: delta != null
                ? 'delta — send ${_fmtBytes(delta.literalBytes)} '
                    '(${(delta.literalBytes * 100 / imageBytes).toStringAsFixed(0)}% of the image; '
                    '${_fmtBytes(delta.copyBytes)} reused from the running slot)'
                : (app.baseEntry == null
                    ? 'full image (no matching base in library)'
                    : 'full image'),
            mono: false,
          ),
          FutureBuilder<int?>(
            future: app.estimateTransferSeconds(),
            builder: (context, snapshot) {
              if (snapshot.data == null) return const SizedBox.shrink();
              return InfoRow(
                  label: 'Estimate',
                  value: _fmtEta(snapshot.data!),
                  mono: false);
            },
          ),
          const SectionHeader('What happens'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '1. The app signs the repeater in as admin and stages the image '
              '(the node\'s SHA-256 gate decides what may boot).\n'
              '2. The image streams in as DIRECT custom packets — never '
              'flooded. The repeater ACKs each window; gaps are re-sent.\n'
              '3. After the last byte, the node re-verifies SHA-256. If it '
              'passes, the update waits for your explicit "Commit update".\n'
              '4. Commit flips the boot partition and reboots. If the new '
              'firmware fails its boot health check (LoRa init + one packet), '
              'the node flips back automatically.',
              style: TextStyle(
                  color: Color(0xFFCBD5E1), fontSize: 12, height: 1.5),
            ),
          ),
          const SectionHeader('Warnings'),
          if (!target.hasDirectRoute && app.manualRoutePath.trim().isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '• No saved direct route to this node — requests reach it '
                'only by flooding. Enter a DIRECT path on this screen, or '
                'save one on the companion (advertise from the repeater).',
                style:
                    TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '• Flashing a different board\'s image is refused by the node '
              '(target check). Flashing a broken image is refused by the '
              'SHA-256 gate. Neither can brick the node.\n'
              '• A low battery suspends staging (battery gate). Charge or '
              'power the node first.\n'
              '• Keep the phone unlocked and in range for the whole transfer.',
              style:
                  TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
            ),
          ),
          const SectionHeader('SHA-256'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              app.selectedAsset?.sha256 != null
                  ? 'Downloaded image verified against the release SHA256SUMS '
                      '(${app.selectedAsset!.name}).'
                  : 'No SHA256SUMS on this release — the device-side SHA-256 '
                      'gate is the integrity decision (by design).',
              style: const TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.45),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TransferScreen()),
              ),
              icon: const Icon(Icons.system_update_alt),
              label: const Text('Start update'),
            ),
          ),
        ],
      ),
    );
  }
}
