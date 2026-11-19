import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'radio_settings_screen.dart';

/// Step 5: work out what is different between the image on this device and the
/// one the repeater is running, by asking the repeater to hash ranges of its
/// own flash. Nothing is staged and the radio is untouched here, so this is a
/// safe place to stop: the transfer only starts from Review.
class CompareScreen extends StatefulWidget {
  const CompareScreen({super.key});

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = context.read<AppState>();
      if (app.remoteDiff == null &&
          !app.comparing &&
          app.compareError == null) {
        unawaited(app.planComparison());
      }
    });
  }

  static String _bytes(int value) => value >= 1024 * 1024
      ? '${(value / (1024 * 1024)).toStringAsFixed(2)} MB'
      : '${(value / 1024).toStringAsFixed(0)} KB';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final diff = app.remoteDiff;
    final progress = app.compareProgress;

    return Scaffold(
      appBar: AppBar(title: const Text('Compare firmware')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 5, label: 'Compare'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'The repeater hashes its own running firmware in small blocks. '
              'Only blocks that differ will be sent — you do not need the old '
              'image on this device.',
              style: TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
            ),
          ),
          if (app.comparing) ...[
            const SectionHeader('Comparing'),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: LinearProgressIndicator(minHeight: 3),
            ),
            const SizedBox(height: 10),
            InfoRow(
              label: 'Ranges checked',
              value: '${progress?.rangesHashed ?? 0}',
            ),
            InfoRow(
              label: 'Exchanges',
              value: '${progress?.queries ?? 0}',
            ),
            InfoRow(
              label: 'Bytes reused so far',
              value: _bytes(progress?.bytesReused ?? 0),
              mono: false,
            ),
          ],
          if (app.compareError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text(
                'Could not compare: ${app.compareError}',
                style: const TextStyle(
                    color: OtaTheme.warn, fontSize: 12, height: 1.5),
              ),
            ),
          if (diff != null) ...[
            SectionHeader(
                diff.upToDate ? 'Already current' : 'Comparison ready'),
            InfoRow(
              label: 'Running image',
              value: _bytes(diff.node.size),
              mono: false,
            ),
            InfoRow(
              label: 'Bytes reused',
              value: _bytes(diff.copyBytes),
              mono: false,
            ),
            InfoRow(
              label: 'Bytes to send',
              value: _bytes(diff.literalBytes),
              mono: false,
            ),
            InfoRow(
              label: 'Exchanges',
              value: '${diff.queries}',
            ),
            if (diff.shiftProbeBatches > 0)
              InfoRow(
                label: 'Shifted matches',
                value: '${diff.shiftProbeBatches}',
              ),
            if (diff.upToDate)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'This node already runs exactly this image. Go back and pick '
                  'a different version, or stop here.',
                  style: TextStyle(
                      color: OtaTheme.warn, fontSize: 12, height: 1.5),
                ),
              ),
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                onPressed: () => unawaited(app.retryComparison()),
                icon: const Icon(Icons.refresh),
                label: const Text('Compare again'),
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: app.comparing
          ? WizardFooter(
              label: 'Comparing…',
              icon: Icons.hourglass_top,
              busy: true,
              onPressed: null,
              hint:
                  'You can stop here — nothing has been sent to the repeater.',
            )
          : app.compareError != null
              ? WizardFooter(
                  label: 'Try again',
                  icon: Icons.refresh,
                  onPressed: () => unawaited(app.retryComparison()),
                  hint: 'Nothing has been sent to the repeater.',
                )
              : diff == null
                  ? const WizardFooter(
                      label: 'Choose firmware first',
                      onPressed: null,
                    )
                  : WizardFooter(
                      label: diff.upToDate
                          ? 'Go back to choose another image'
                          : 'Next: radio settings',
                      onPressed: diff.upToDate
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const RadioSettingsScreen()),
                              ),
                      hint: 'Nothing has been staged. The transfer only starts '
                          'after Review.',
                    ),
    );
  }
}
