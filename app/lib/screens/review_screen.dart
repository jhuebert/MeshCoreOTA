import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/radio_plan.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'transfer_screen.dart';

/// Step 7: a summary of everything chosen, before anything goes on air. The
/// comparison with the node's running image and the radio plan are both done
/// on earlier steps; this screen only confirms what will happen. Start boots
/// nothing — the transfer screen stages into the spare slot and the node only
/// applies anything on the final commit.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  String _fmtEta(int seconds) {
    if (seconds < 120) return '~${seconds}s';
    final minutes = (seconds / 60).ceil();
    if (minutes < 90) return '~$minutes min';
    return '~${(minutes / 60).toStringAsFixed(1)} h';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.target!;
    final status = app.nodeStatus;
    final imageBytes = app.selectedImage?.length ?? 0;
    final plan = app.radioPlan;
    final planProblem = app.radioPlanProblem;
    final imageIsRunning = app.selectedImageIsRunning;

    return Scaffold(
      appBar: AppBar(title: const Text('Review update')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 7, label: 'Review'),
          const SectionHeader('Companion'),
          InfoRow(
            label: 'Companion',
            value: app.companionName.isNotEmpty
                ? app.companionName
                : '(unnamed companion)',
            mono: false,
          ),
          InfoRow(
            label: 'Connected via',
            value: _connectionLabel(app),
            mono: false,
          ),
          const SectionHeader('Repeater'),
          InfoRow(
            label: 'Repeater',
            value: target.name.isNotEmpty ? target.name : '(unnamed)',
            mono: false,
          ),
          InfoRow(
            label: 'Board',
            value: app.detectedBoard ??
                (app.nodeInfo == null ? 'unknown' : 'custom build'),
            mono: app.detectedBoard != null,
          ),
          InfoRow(
            label: 'Current firmware',
            value: status?.running.isNotEmpty == true ? status!.running : '?',
          ),
          const SectionHeader('This update'),
          InfoRow(label: 'Update to', value: app.selectedDisplayVersion ?? '?'),
          InfoRow(
              label: 'Image size', value: _fmtBytes(imageBytes), mono: false),
          InfoRow(
              label: 'Transfer',
              value: _transferLabel(app, imageBytes),
              mono: false),
          FutureBuilder<int?>(
            future: app.estimateTransferSeconds(),
            builder: (context, snapshot) {
              if (snapshot.data == null) return const SizedBox.shrink();
              return InfoRow(
                  label: 'Estimated time',
                  value: _fmtEta(snapshot.data!),
                  mono: false);
            },
          ),
          InfoRow(label: 'Radio', value: _radioLabel(app), mono: false),
          if (imageIsRunning)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                'This node is already running this image — there is nothing '
                'to send. Go back and pick a different one.',
                style:
                    TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
              ),
            ),
          if (app.remoteDiff != null && !imageIsRunning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                'Matched against the running image on the repeater: '
                '${_fmtBytes(app.remoteDiff!.copyBytes)} reused, '
                '${app.remoteDiff!.queries} comparisons'
                '${app.remoteDiff!.shiftProbeBatches > 0 ? ', including shifted matches' : ''}.',
                style: const TextStyle(
                    color: OtaTheme.textMuted, fontSize: 11, height: 1.4),
              ),
            ),
          if (plan.mode == RadioMode.liveMesh &&
              !target.hasDirectRoute &&
              app.manualRoutePath.trim().isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                'No saved route to this repeater — it only hears requests by '
                'flooding. Set a direct path on the radio step, or use a '
                'private channel.',
                style:
                    TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
              ),
            ),
          const SectionHeader('Warnings'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '• The repeater pauses updates when its battery is low — charge '
              'or power it first.\n'
              '• Keep the phone in range and the screen on for the whole '
              'transfer.',
              style:
                  TextStyle(color: OtaTheme.warn, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
      bottomNavigationBar: WizardFooter(
        label: imageIsRunning ? 'Already up to date' : 'Start update',
        icon: Icons.system_update_alt,
        onPressed: planProblem != null ||
                imageIsRunning ||
                app.remoteDiff == null ||
                app.comparing
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TransferScreen()),
                ),
        hint: planProblem,
      ),
    );
  }

  String _connectionLabel(AppState app) {
    if (app.transportKind == 'tcp') {
      return 'TCP — ${app.tcpHost}:${app.tcpPort}';
    }
    if (app.transportKind == 'ble') {
      return 'Bluetooth';
    }
    return 'Companion';
  }

  String _transferLabel(AppState app, int imageBytes) {
    final diff = app.remoteDiff;
    if (diff == null) return 'Comparing with the repeater…';
    final pct = imageBytes > 0
        ? (diff.literalBytes * 100 / imageBytes).toStringAsFixed(0)
        : '0';
    return '${diff.upToDate ? 'Nothing to send' : 'Changes only'} — '
        'send ${_fmtBytes(diff.literalBytes)} ($pct% of the image)';
  }

  String _radioLabel(AppState app) {
    final plan = app.radioPlan;
    switch (plan.mode) {
      case RadioMode.liveMesh:
        final live = app.livePreset;
        final base = live == null ? 'Live mesh' : 'Live mesh (${live.label})';
        final route = app.manualRoutePath.trim();
        return route.isEmpty ? base : '$base — direct override $route';
      case RadioMode.tempRadio:
        return 'Temporary private channel — '
            '${plan.preset?.label ?? '?'} (renews automatically)';
      case RadioMode.radio2:
        return 'The repeater’s second preset — ${plan.preset?.label ?? '?'}';
    }
  }
}
