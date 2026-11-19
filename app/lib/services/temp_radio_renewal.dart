import 'radio_plan.dart';

/// State for the automatic `tempradio` window.
///
/// The repeater accepts another `tempradio` command at any time; the last one
/// wins and overwrites the expiry, so renewing before the old window lapses
/// keeps the channel live without a gap. This class owns only the timing and
/// the failure count — the caller supplies the actual command and its result.
///
/// Kept free of Flutter and platform imports so the rule is unit-testable
/// without waiting ten real minutes.
class TempRadioRenewal {
  TempRadioRenewal({DateTime Function()? now}) : now = now ?? DateTime.now;

  /// Test seam; production uses the wall clock.
  DateTime Function() now;

  DateTime? _armedAt;

  /// Two consecutive failed renewals mean the channel can no longer be
  /// trusted; the transfer pauses so a later resume arms a fresh window.
  int failures = 0;
  bool get abandoned => failures >= 2;

  /// Start (or restart) timing from a fresh `tempradio` arm.
  void arm() {
    _armedAt = now();
    failures = 0;
  }

  void clear() {
    _armedAt = null;
    failures = 0;
  }

  /// Renew once the current chunk has been live long enough. [renew] must
  /// return true only when the node acknowledged the new command.
  ///
  /// Returns true when a renewal was attempted, regardless of its result.
  Future<bool> maybeRenew({required Future<bool> Function() renew}) async {
    final armedAt = _armedAt;
    if (armedAt == null ||
        !RadioPlan.shouldRenewTempRadio(now().difference(armedAt))) {
      return false;
    }
    final ok = await renew();
    if (ok) {
      _armedAt = now();
      failures = 0;
    } else {
      failures++;
    }
    return true;
  }
}
