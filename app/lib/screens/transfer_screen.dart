import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:ota_core/ota_core.dart' show TransferProgress;

import '../app_state.dart';
import '../services/foreground.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'resume_screen.dart';
import 'verify_screen.dart';

/// Step 8: the transfer itself. The node re-verifies the image when the
/// stream ends. Nothing boots until the operator commits.
class TransferScreen extends StatefulWidget {
  /// A resumed transfer keeps the staged bytes when cancelled; a fresh one
  /// discards them.
  const TransferScreen({super.key, this.resuming = false});

  final bool resuming;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  final _logController = ScrollController();
  bool _started = false;
  String? _error;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _logController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    final app = context.read<AppState>();
    final nodeName = app.target?.name ?? 'node';
    try {
      await TransferForegroundService.start('Preparing update for $nodeName');
    } catch (e) {
      // foreground start failure: log and continue — the update itself is
      // unaffected, but say so honestly.
      app.log_('foreground service unavailable: $e — keep the screen on');
    }
    try {
      if (widget.resuming) {
        await app.resumeTransfer();
      } else {
        await app.runUpdate(version: app.selectedVersion ?? 'unknown');
      }
    } on UpdatePausedException catch (_) {
      if (mounted) setState(() => _paused = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      await TransferForegroundService.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final progress = app.progress;
    final phase = app.updatePhase;
    final target = app.target;

    // Auto-scroll the log.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logController.hasClients) {
        _logController.jumpTo(_logController.position.maxScrollExtent);
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Updating')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 8, label: 'Transfer'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              target == null
                  ? 'Updating…'
                  : 'Updating ${target.name.isNotEmpty ? target.name : 'the node'} to '
                      '${app.selectedDisplayVersion ?? '?'}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress?.fraction,
                    minHeight: 10,
                    backgroundColor: OtaTheme.surfaceHigh,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(OtaTheme.accent),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  progress == null
                      ? 'Preparing…'
                      : '${((progress.fraction ?? 0) * 100).toStringAsFixed(1)}%  ·  '
                          '${progress.packetsSent} packets · '
                          '${progress.retries} re-sends · '
                          '${(progress.literalBytesSent / 1024).toStringAsFixed(0)} KB sent · '
                          '${progress.elapsed.inSeconds}s',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
                if (progress != null) _EtaLine(progress: progress),
              ],
            ),
          ),
          const SectionHeader('Steps'),
          _stepRow(
            label: 'Stage image',
            state: phase.index >= UpdatePhase.staging.index
                ? _StepState.ok
                : _StepState.pending,
          ),
          _stepRow(
            label: 'Transfer',
            state: phase.index >= UpdatePhase.readyToApply.index
                ? _StepState.ok
                : phase == UpdatePhase.transferring
                    ? _StepState.active
                    : _StepState.pending,
          ),
          _stepRow(
            label: 'Verify the image',
            state: phase.index >= UpdatePhase.readyToApply.index
                ? _StepState.ok
                : phase == UpdatePhase.transferring
                    ? _StepState.active
                    : _StepState.pending,
          ),
          _stepRow(
            label: 'Commit update',
            state: phase.index >= UpdatePhase.verifying.index
                ? _StepState.ok
                : phase == UpdatePhase.applying ||
                        phase == UpdatePhase.readyToApply
                    ? _StepState.active
                    : _StepState.pending,
          ),
          if (_paused) ...[
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.pause_circle_outline,
                            color: OtaTheme.accent),
                        SizedBox(width: 10),
                        Text('Update paused',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'The repeater kept the part it already received, and '
                      'the firmware is still on this device. Nothing was '
                      'applied. Continue any time from the Connect screen — '
                      'only the missing part will be sent.',
                      style: TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_error != null) ErrorBanner(_error!),
          if (phase == UpdatePhase.failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back — nothing was applied'),
              ),
            ),
          const SectionHeader('Log'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              height: 180,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: OtaTheme.surfaceHigh),
              ),
              child: Scrollbar(
                controller: _logController,
                child: ListView.builder(
                  controller: _logController,
                  itemCount: app.log.length,
                  itemBuilder: (context, index) => Text(
                    app.log[index],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: Color(0xFF9FE8B5),
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _buildFooter(context, app, phase),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context, AppState app, UpdatePhase phase) {
    if (_paused) {
      return FilledButton.icon(
        onPressed: () => Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ResumeScreen()),
          (route) => route.isFirst,
        ),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Continue this update'),
      );
    }
    switch (phase) {
      case UpdatePhase.transferring:
      case UpdatePhase.staging:
      case UpdatePhase.probing:
        return OutlinedButton.icon(
          onPressed: () => context.read<AppState>().requestCancel(),
          icon: const Icon(Icons.close),
          label: const Text('Pause — keep what was already uploaded'),
        );
      case UpdatePhase.readyToApply:
        return FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const VerifyScreen()),
          ),
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Commit update — reboot into new firmware'),
        );
      case UpdatePhase.done:
        return FilledButton.icon(
          onPressed: () => Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const VerifyScreen()),
            (route) => route.isFirst,
          ),
          icon: const Icon(Icons.verified),
          label: const Text('See verification'),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _stepRow({required String label, required _StepState state}) {
    final (icon, color) = switch (state) {
      _StepState.pending => (Icons.radio_button_unchecked, OtaTheme.textMuted),
      _StepState.active => (Icons.timelapse, OtaTheme.accent),
      _StepState.ok => (Icons.check_circle, OtaTheme.ok),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: color, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

enum _StepState { pending, active, ok }

/// Time left at the measured rate of the current transfer, so the operator
/// can plan around a real number instead of the airtime-only pre-estimate.
class _EtaLine extends StatelessWidget {
  const _EtaLine({required this.progress});

  final TransferProgress progress;

  @override
  Widget build(BuildContext context) {
    final applied = progress.opsApplied;
    if (applied == null || applied < 4 || progress.elapsed.inSeconds < 5) {
      return const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('Measuring the transfer rate…',
            style: TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
      );
    }
    final rate = applied / progress.elapsed.inSeconds; // ops per second
    final remainingOps =
        (progress.opsTotal - applied).clamp(0, progress.opsTotal);
    final remaining = Duration(seconds: (remainingOps / rate).ceil());
    final rateText =
        rate >= 10 ? rate.toStringAsFixed(0) : rate.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '≈ ${_etaText(remaining)} left at the current rate · '
        '$rateText ops/s',
        style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
      ),
    );
  }

  static String _etaText(Duration d) {
    if (d.inMinutes < 2) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  }
}
