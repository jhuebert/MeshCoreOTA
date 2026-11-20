import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'firmware_screen.dart';
import 'transfer_screen.dart';
import 'verify_screen.dart';

/// Recovery flow for an update that was interrupted by a crash or a rebooted
/// phone. The repeater is the authority on how much it already received; the
/// app's saved frames let us continue without sending that part again.
class ResumeScreen extends StatefulWidget {
  const ResumeScreen({super.key});

  @override
  State<ResumeScreen> createState() => _ResumeScreenState();
}

class _ResumeScreenState extends State<ResumeScreen> {
  final _passwordController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _check(AppState app) async {
    setState(() => _error = null);
    try {
      await app.prepareResume(password: _passwordController.text);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _continue(AppState app) async {
    setState(() => _error = null);
    try {
      app.finishResumeApply();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const VerifyScreen()),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _differentFirmware(AppState app) async {
    setState(() => _error = null);
    try {
      await app.cancelResume();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const FirmwareScreen()),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final plan = app.resumePlan;
    if (plan == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Continue update')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'There is no interrupted update to continue.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final check = app.resumeCheck;
    final busy = app.resumeBusy;
    final status = app.resumeStatus;
    final saved = plan.frames.isEmpty
        ? 0.0
        : ((plan.nextExpected - 1) / plan.frames.length).clamp(0.0, 1.0);
    final fraction =
        check == ResumeCheck.ready && status != null && status.size > 0
            ? (status.offset / status.size).clamp(0.0, 1.0)
            : saved;
    final needsPassword =
        check == ResumeCheck.idle || check == ResumeCheck.needsLogin;

    String label;
    String emoji;
    VoidCallback? action;
    switch (check) {
      case ResumeCheck.ready:
        label = 'Resume upload';
        emoji = playEmoji;
        action = () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const TransferScreen(resuming: true)),
            );
      case ResumeCheck.readyToApply:
        label = 'Apply update';
        emoji = playEmoji;
        action = () => _continue(app);
      case ResumeCheck.unavailable:
        // A temporary failure must not be a dead end: recheck the repeater
        // before offering to throw the saved upload away.
        label = 'Check again';
        emoji = nextEmoji;
        action = () => _check(app);
      default:
        label = 'Check update';
        emoji = nextEmoji;
        action = () => _check(app);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Continue update')),
      bottomNavigationBar: WizardFooter(
        label: label,
        emoji: emoji,
        onPressed: busy ? null : action,
        busy: busy,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 20),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'An update was interrupted. If the repeater still has the part '
              'that was already sent, only the rest is uploaded. You do not '
              'have to start over.',
              style: const TextStyle(
                  color: OtaTheme.textMuted, fontSize: 13, height: 1.5),
            ),
          ),
          const SectionHeader('Saved update'),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(plan.targetName.isEmpty ? 'Repeater' : plan.targetName,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Firmware ${plan.version}',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12)),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: fraction,
                    color: OtaTheme.accent,
                    backgroundColor: OtaTheme.surfaceHigh,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    check == ResumeCheck.readyToApply
                        ? 'Fully uploaded and checked. Not applied yet.'
                        : '${(fraction * 100).round()}% of ${_mb(plan.imageSize)} uploaded',
                    style: const TextStyle(
                        color: OtaTheme.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          if (needsPassword) ...[
            const SectionHeader('Admin sign-in'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'The admin password is never saved. Enter it again to check '
                'the repeater. Leave it empty if this companion is already in '
                'the repeater’s admin list.',
                style: const TextStyle(
                    color: OtaTheme.textMuted, fontSize: 12, height: 1.4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: TextField(
                controller: _passwordController,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Admin password (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
          if (busy)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text('Checking the repeater…',
                  style: TextStyle(color: OtaTheme.textMuted, fontSize: 12)),
            ),
          if (app.resumeProblem != null && !busy)
            ErrorBanner(app.resumeProblem!),
          if (_error != null) ErrorBanner(_error!),
          if (check == ResumeCheck.ready ||
              check == ResumeCheck.readyToApply ||
              check == ResumeCheck.unavailable)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => _differentFirmware(app),
                icon: const Text(backEmoji),
                label: const Text('Start a different update'),
              ),
            ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Cancelling discards the repeater’s staged image so the next '
              'update can start cleanly.',
              style: const TextStyle(
                  color: OtaTheme.textMuted, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
