import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';

/// Final step: boot into the new image and prove it works. The node
/// rebooted into an image its hash gate approved; the boot health check
/// flips back if the LoRa radio is dead. The app adds the last mile:
/// re-login and confirm the image hash matches the one that was sent.
class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  bool _started = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
  }

  Future<void> _apply() async {
    if (_started) return;
    _started = true;
    final app = context.read<AppState>();
    try {
      await app.applyAndVerify(expectedVersion: app.selectedVersion ?? '');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final phase = app.updatePhase;
    final matched = app.verifyMatched;

    return Scaffold(
      appBar: AppBar(title: const Text('Verify')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 9, label: 'Verify'),
          const SizedBox(height: 18),
          if (phase == UpdatePhase.applying || phase == UpdatePhase.verifying)
            const Column(
              children: [
                SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                Text(
                  'Node is rebooting into the new firmware…\n'
                  'Waiting for it to answer admin CLI again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: OtaTheme.textMuted, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          if (_error != null) ErrorBanner(_error!),
          if (phase == UpdatePhase.done || phase == UpdatePhase.failed) ...[
            Center(
              child: Icon(
                app.rolledBack
                    ? Icons.undo
                    : matched
                        ? Icons.check_circle
                        : Icons.warning_amber_rounded,
                size: 84,
                color: app.rolledBack
                    ? OtaTheme.warn
                    : matched
                        ? OtaTheme.ok
                        : OtaTheme.warn,
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                app.rolledBack
                    ? 'Rolled back to the previous firmware'
                    : matched
                        ? 'Update verified'
                        : 'New firmware did not come up',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  app.rolledBack
                      ? 'The repeater rebooted into the firmware it ran before '
                          'this update. Nothing was re-flashed.'
                      : matched
                          ? 'The repeater came back on the new firmware — its '
                              'image matches the one that was sent. The update is '
                              'complete.'
                          : 'The node is not running the expected image. Either it '
                              'switched itself back to the previous firmware (the '
                              'safe outcome), or the new image is broken. Check the '
                              'node — you can roll back below.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: OtaTheme.textMuted, fontSize: 12.5, height: 1.5),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OutlinedButton.icon(
              // A rollback while apply/verify is still deciding would race the
              // in-flight reboot: the outcome is not known yet.
              onPressed: phase == UpdatePhase.applying ||
                      phase == UpdatePhase.verifying
                  ? null
                  : () => _rollback(app),
              icon: const Icon(Icons.undo),
              label: const Text('Roll back to previous firmware'),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).popUntil((route) => route.isFirst),
              icon: const Icon(Icons.home_outlined),
              label: const Text('Done — back to start'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rollback(AppState app) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Roll back?'),
        content: const Text(
          'The repeater reboots into the previous firmware. Nothing is '
          're-flashed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep current firmware'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Roll back'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await app.rollback();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rollback failed: $e')),
        );
      }
    }
  }
}
