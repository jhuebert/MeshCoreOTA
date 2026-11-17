import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/firmware_library.dart';
import '../services/radio_plan.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'radio_settings_screen.dart';
import 'transfer_screen.dart';

/// Step 5: everything about the update before anything goes on air. The app
/// picks the parameters; the node only applies ops and verifies SHA-256.
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
    if (seconds < 120) return '~${seconds}s at the transfer radio settings';
    final minutes = (seconds / 60).ceil();
    return '~$minutes min at the transfer radio settings';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.target!;
    final status = app.nodeStatus;
    final delta = app.deltaResult;
    final imageBytes = app.selectedImage?.length ?? 0;
    final plan = app.radioPlan;
    final planProblem = app.radioPlanProblem;
    final imageIsRunning = app.selectedImageIsRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Review update')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 5, label: 'Review the update'),
          const SectionHeader('Node'),
          InfoRow(
              label: 'Node',
              value: target.name.isNotEmpty ? target.name : '(unnamed)',
              mono: false),
          InfoRow(label: 'Running', value: status?.running ?? '?'),
          if (app.detectedBoard != null)
            InfoRow(label: 'Board', value: app.detectedBoard!),
          const SectionHeader('Radio'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      switch (plan.mode) {
                        RadioMode.liveMesh => 'Live mesh',
                        RadioMode.tempRadio => 'Temporary private channel',
                        RadioMode.radio2 => 'The repeater\'s second preset',
                      },
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _radioSummary(app),
                      style: const TextStyle(
                          color: OtaTheme.textMuted,
                          fontSize: 12,
                          height: 1.45),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const RadioSettingsScreen()),
                      ),
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('Change radio settings'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (plan.mode == RadioMode.liveMesh) ...[
            if (app.manualRouteError != null)
              ErrorBanner(app.manualRouteError!),
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
                      'Comma-separated hash hops. Empty keeps the saved route; '
                      'the override is pushed to the companion (like change_path).',
                  errorText: app.manualRouteError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: app.setManualRoutePath,
              ),
            ),
          ],
          if (planProblem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                planProblem,
                style: const TextStyle(color: OtaTheme.bad, fontSize: 12),
              ),
            ),
          const SectionHeader('Images'),
          InfoRow(label: 'Install', value: app.selectedEnvironment ?? '?'),
          InfoRow(label: 'To version', value: app.selectedVersion ?? '?'),
          InfoRow(label: 'Image size', value: _fmtBytes(imageBytes)),
          InfoRow(
            label: 'Base',
            value: _baseDescription(app),
            mono: false,
          ),
          if (imageIsRunning)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'This node is already running this image — the transfer '
                'would send nothing. Choose a different image, or pick '
                '\'Full image\' in the base picker to re-flash this one '
                'deliberately.',
                style:
                    TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
              ),
            ),
          if (_manualBaseMismatch(app))
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'The chosen base is not the image this node reports running. '
                'The delta will not reproduce the target and the node\'s '
                'SHA-256 gate will refuse it (nothing boots); choose the base '
                'the node actually has, or send the full image.',
                style:
                    TextStyle(color: OtaTheme.warn, fontSize: 11, height: 1.45),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickBase(app),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Choose base'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: const Text('Change image'),
                  ),
                ),
              ],
            ),
          ),
          InfoRow(
            label: 'Transfer',
            value: delta != null
                ? 'delta — send ${_fmtBytes(delta.literalBytes)} '
                    '(${(delta.literalBytes * 100 / imageBytes).toStringAsFixed(0)}% of the image; '
                    '${_fmtBytes(delta.copyBytes)} reused from the running slot)'
                : (app.baseEntry == null
                    ? 'full image (no delta base)'
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
              '2. Each op rides inside an ordinary encrypted admin REQ to the '
              'node. The companion routes it along the saved DIRECT path, or '
              'floods when it has none.\n'
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
          if (plan.mode == RadioMode.liveMesh &&
              !target.hasDirectRoute &&
              app.manualRoutePath.trim().isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '• No saved direct route to this node — requests reach it '
                'only by flooding. Enter a DIRECT path on this screen, use a '
                'private radio in the step above, or save a route on the '
                'companion (advertise from the repeater).',
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
              onPressed: planProblem != null || imageIsRunning
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TransferScreen()),
                      ),
              icon: const Icon(Icons.system_update_alt),
              label:
                  Text(imageIsRunning ? 'Already up to date' : 'Start update'),
            ),
          ),
        ],
      ),
    );
  }

  String _radioSummary(AppState app) {
    final plan = app.radioPlan;
    final preset = plan.preset;
    switch (plan.mode) {
      case RadioMode.liveMesh:
        final target = app.target!;
        final route = app.manualRoutePath.trim().isNotEmpty
            ? 'direct override: ${app.manualRoutePath.trim()} (pushed to the companion)'
            : (target.hasDirectRoute
                ? ((target.outPathLen & 0x3F) == 0
                    ? 'direct, zero hop'
                    : 'direct, ${target.outPathLen & 0x3F} hop(s)')
                : 'no saved route — requests flood');
        final live = app.livePreset;
        return 'On the normal mesh${live == null ? '' : ' (${live.label})'}; '
            '$route.';
      case RadioMode.tempRadio:
        return 'Both ends move to ${preset?.label ?? 'a private preset'} for '
            '${plan.durationMinutes} min, then return. Zero-hop only, so the '
            'live mesh never sees the transfer.';
      case RadioMode.radio2:
        final already = app.radio2Enabled == true;
        return 'The node keeps its live preset and the transfer uses its second '
            'preset${preset == null ? '' : ' (${preset.label})'}; the companion '
            'is tuned to it for ${plan.durationMinutes} min. '
            '${already ? 'radio2 is already enabled — the node configuration is left alone.' : 'The app enables radio2 for the update and turns it off afterwards.'} '
            'Zero-hop on the secondary, and about '
            '${RadioPlan.radio2DutyFactor.toStringAsFixed(0)}× the airtime because '
            'the repeater shares the radio with the live mesh.';
    }
  }

  String _baseDescription(AppState app) {
    if (app.forceFullImage) return 'full image (chosen)';
    final base = app.baseEntry;
    if (base == null) return 'full image (no matching base in the library)';
    if (app.baseIsManual) return '${base.fileName} (chosen manually)';
    if (_baseMatchesRunning(app, base)) {
      return '${base.fileName} (matched the node\'s image hash)';
    }
    return '${base.fileName} (matched the running version)';
  }

  bool _baseMatchesRunning(AppState app, LibraryEntry base) {
    final info = app.nodeInfo;
    if (info == null) return false;
    final running = info.runningSha256
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return base.sha256 == running;
  }

  bool _manualBaseMismatch(AppState app) =>
      !app.forceFullImage &&
      app.baseIsManual &&
      app.baseEntry != null &&
      app.nodeInfo != null &&
      !_baseMatchesRunning(app, app.baseEntry!);

  Future<void> _pickBase(AppState app) async {
    final entries = app.libraryEntries;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OtaTheme.surface,
      builder: (sheetContext) {
        final currentId = app.baseEntry?.id;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const ListTile(
                  dense: true,
                  title: Text('Delta base',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    'The image the node already has. A matching base makes the '
                    'update a delta; anything else sends the whole image.',
                    style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                  ),
                ),
                ListTile(
                  leading:
                      const Icon(Icons.auto_awesome, color: OtaTheme.accent),
                  title: const Text('Automatic'),
                  subtitle: const Text('Match the node\'s running image'),
                  trailing: (!app.forceFullImage && !app.baseIsManual)
                      ? const Icon(Icons.check, color: OtaTheme.accent)
                      : null,
                  onTap: () async {
                    await app.setBaseOverride(null);
                    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Full image'),
                  subtitle: const Text('Send every byte, no base needed'),
                  trailing: app.forceFullImage
                      ? const Icon(Icons.check, color: OtaTheme.accent)
                      : null,
                  onTap: () async {
                    await app.setFullImage(true);
                    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                  },
                ),
                const Divider(),
                if (entries.isEmpty)
                  const ListTile(
                    dense: true,
                    title: Text('The library is empty',
                        style: TextStyle(color: OtaTheme.textMuted)),
                  ),
                for (final entry in entries)
                  ListTile(
                    leading:
                        const Icon(Icons.memory, color: OtaTheme.textMuted),
                    title: Text(entry.fileName,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                    subtitle: Text(
                      '${entry.env} · ${entry.version} · '
                      '${(entry.size / (1024 * 1024)).toStringAsFixed(2)} MB',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 11),
                    ),
                    trailing: entry.id == currentId
                        ? const Icon(Icons.check, color: OtaTheme.accent)
                        : null,
                    onTap: () async {
                      await app.setBaseOverride(entry);
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
