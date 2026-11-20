import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart' show nextEmoji;

/// The update is one path from a connected companion to verified firmware.
/// Every screen carries the same progress line so the operator always knows
/// where they are and what is still ahead.
class WizardBar extends StatelessWidget implements PreferredSizeWidget {
  const WizardBar({super.key, required this.step, required this.label});

  /// 1-based step number.
  final int step;
  final String label;

  /// Height reserved in an app bar's `bottom` for the progress line.
  static const double height = 46;

  static const steps = <String>[
    'Connect',
    'Repeater',
    'Sign in',
    'Firmware',
    'Radio',
    'Review',
    'Transfer',
    'Verify',
  ];

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final total = steps.length;
    final current = step.clamp(1, total);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: current / total,
              minHeight: 3,
              backgroundColor: OtaTheme.surfaceHigh,
              valueColor: const AlwaysStoppedAnimation<Color>(OtaTheme.accent),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                'Step $current of $total',
                style: const TextStyle(
                  color: OtaTheme.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The progress line and a screen's tabs, stacked under the app bar title.
/// Both live in `AppBar.bottom`, so the progress line sits directly below the
/// title and back arrow — above the tabs, as it does on every other step.
class WizardTabBar extends StatelessWidget implements PreferredSizeWidget {
  const WizardTabBar({
    super.key,
    required this.step,
    required this.label,
    required this.tabs,
    this.controller,
  });

  final int step;
  final String label;
  final List<Widget> tabs;
  final TabController? controller;

  @override
  Size get preferredSize => const Size.fromHeight(
        WizardBar.height + kTextTabBarHeight,
      );

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          WizardBar(step: step, label: label),
          TabBar(
            controller: controller,
            indicatorColor: OtaTheme.accent,
            tabs: tabs,
          ),
        ],
      );
}

/// A bottom action bar for a wizard step: one primary "next" action plus an
/// optional explanation of why it is unavailable.
class WizardFooter extends StatelessWidget {
  const WizardFooter({
    super.key,
    required this.label,
    required this.onPressed,
    this.emoji = nextEmoji,
    this.busy = false,
    this.hint,
  });

  final String label;
  final VoidCallback? onPressed;
  final String emoji;
  final bool busy;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: OtaTheme.surface,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  hint!,
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                ),
              ),
            FilledButton.icon(
              onPressed: busy ? null : onPressed,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF1A1203),
                      ),
                    )
                  : Text(emoji),
              label: Text(label),
            ),
          ],
        ),
      ),
    );
  }
}
