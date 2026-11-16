/// The radio a transfer runs on.
///
/// The update traffic is heavy for a production mesh, so the operator can
/// move it off the live preset: both ends switch to a temporary private
/// channel (`tempradio`, on the repeater and on the companion), or the
/// repeater keeps serving the live mesh and the transfer uses its second
/// preset (`radio2`). Both off-mesh modes are zero-hop by definition — no
/// relay is on those settings.
///
/// Everything here is pure: the screens format and validate with it, and the
/// update flow turns it into the CLI commands the node and companion accept.
library;

/// A LoRa preset in the units the firmware's `get radio` reply uses
/// (`freq MHz, bw kHz, sf, cr`).
class LoRaPreset {
  const LoRaPreset({
    required this.frequencyHz,
    required this.bandwidthHz,
    required this.spreadingFactor,
    required this.codingRate,
  });

  final int frequencyHz;
  final int bandwidthHz;
  final int spreadingFactor;
  final int codingRate;

  double get frequencyMhz => frequencyHz / 1e6;
  double get bandwidthKhz => bandwidthHz / 1e3;

  /// The `get radio` / `tempradio` / `radio2` argument form.
  String get cli =>
      '${_fmt(frequencyMhz, 3)},${_fmt(bandwidthKhz, 3)},$spreadingFactor,$codingRate';

  String get label =>
      '${_fmt(frequencyMhz, 3)} MHz · ${_fmt(bandwidthKhz, 3)} kHz · '
      'SF$spreadingFactor · CR4/$codingRate';

  /// Parse a firmware `get radio` reply (`> 910.525,62.5,7,5`) or a bare
  /// `freq,bw,sf,cr` list. Returns null when it is not a preset.
  static LoRaPreset? parse(String text) {
    final cleaned = text.replaceFirst(RegExp(r'^\s*>?\s*'), '').trim();
    final parts = cleaned.split(',');
    if (parts.length != 4) return null;
    final freq = double.tryParse(parts[0].trim());
    final bw = double.tryParse(parts[1].trim());
    final sf = int.tryParse(parts[2].trim());
    final cr = int.tryParse(parts[3].trim());
    if (freq == null || bw == null || sf == null || cr == null) return null;
    return LoRaPreset(
      frequencyHz: (freq * 1e6).round(),
      bandwidthHz: (bw * 1e3).round(),
      spreadingFactor: sf,
      codingRate: cr,
    );
  }

  /// The preset a node is built with when it cannot be asked (`get radio`) —
  /// the companion's own preset, which is the same mesh.
  LoRaPreset copyWith({
    int? frequencyHz,
    int? bandwidthHz,
    int? spreadingFactor,
    int? codingRate,
  }) =>
      LoRaPreset(
        frequencyHz: frequencyHz ?? this.frequencyHz,
        bandwidthHz: bandwidthHz ?? this.bandwidthHz,
        spreadingFactor: spreadingFactor ?? this.spreadingFactor,
        codingRate: codingRate ?? this.codingRate,
      );

  /// Whether [other] tunes a band that overlaps this one. The firmware's
  /// radio2 rule: half of each bandwidth plus a 6 kHz guard.
  bool overlaps(LoRaPreset other) {
    final distance = (frequencyHz - other.frequencyHz).abs();
    final reach = (bandwidthHz + other.bandwidthHz) ~/ 2 + 6000;
    return distance <= reach;
  }

  /// A human-readable range problem, or null when the preset is syntactically
  /// usable by the firmware (150–2500 MHz, 7–500 kHz, SF5–12, CR5–8).
  String? get rangeError {
    if (frequencyMhz < 150 || frequencyMhz > 2500) {
      return 'frequency must be 150–2500 MHz';
    }
    if (bandwidthKhz < 7 || bandwidthKhz > 500) {
      return 'bandwidth must be 7–500 kHz';
    }
    if (spreadingFactor < 5 || spreadingFactor > 12) {
      return 'spreading factor must be 5–12';
    }
    if (codingRate < 5 || codingRate > 8) {
      return 'coding rate must be 4/5–4/8 (5–8)';
    }
    return null;
  }

  static String _fmt(double value, int maxDecimals) {
    var text = value.toStringAsFixed(maxDecimals);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      text = text.replaceFirst(RegExp(r'\.$'), '');
    }
    return text;
  }
}

enum RadioMode {
  /// The node keeps its normal preset and the oplog uses the saved route or
  /// a manual DIRECT path.
  liveMesh,

  /// Both the repeater and the companion move to a temporary private preset
  /// for the duration of the transfer.
  tempRadio,

  /// The repeater's second preset carries the transfer while the primary
  /// keeps serving the live mesh.
  radio2,
}

/// The operator's choice for how the update reaches the node.
class RadioPlan {
  const RadioPlan({
    this.mode = RadioMode.liveMesh,
    this.preset,
    this.durationMinutes = defaultDurationMinutes,
  });

  static const int defaultDurationMinutes = 10;
  static const int minDurationMinutes = 1;
  static const int maxDurationMinutes = 720;

  /// radio2 shares the radio with the live mesh: the repeater only listens on
  /// the secondary preset for part of each cycle (more when the primary is
  /// quiet). A transfer therefore takes roughly twice the airtime the same
  /// preset would need on its own. The suggestion is deliberately
  /// conservative; the real share is in `radio2 timing` on the node.
  static const double radio2DutyFactor = 2.0;

  final RadioMode mode;

  /// The private preset for [RadioMode.tempRadio] / [RadioMode.radio2].
  final LoRaPreset? preset;

  /// How long the temporary preset stays in place. Applies to the repeater's
  /// `tempradio` and to the companion's (which is always a tempradio, even in
  /// radio2 mode).
  final int durationMinutes;

  /// Both off-mesh modes require zero-hop: no other node is tuned there.
  bool get requiresZeroHop => mode != RadioMode.liveMesh;

  /// Whether this mode moves a radio off the live preset (regardless of
  /// whether a preset has been chosen yet).
  bool get usesRadio => mode != RadioMode.liveMesh;

  /// Multiplier applied to the airtime estimate for this mode.
  double get estimateFactor =>
      mode == RadioMode.radio2 ? radio2DutyFactor : 1.0;

  /// "~90s", "~3 min", or "unknown" — the estimate shown before a transfer.
  static String describeSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return 'unknown';
    if (seconds < 120) return '~${seconds}s';
    return '~${(seconds / 60).ceil()} min';
  }

  /// `tempradio <freq>,<bw>,<sf>,<cr>,<mins>`.
  String get tempRadioCommand => 'tempradio ${preset!.cli},$durationMinutes';

  /// `radio2 <freq>,<bw>,<sf>,<cr>` (setting a preset is how it is enabled).
  String get radio2Command => 'radio2 ${preset!.cli}';

  /// Why the plan cannot run, or null when it is usable. [primary] is the
  /// node's current preset — needed for radio2's no-overlap rule.
  String? error({LoRaPreset? primary}) {
    if (mode == RadioMode.liveMesh) return null;
    final p = preset;
    if (p == null) return 'choose the radio settings for this mode';
    final range = p.rangeError;
    if (range != null) return range;
    if (durationMinutes < minDurationMinutes ||
        durationMinutes > maxDurationMinutes) {
      return 'duration must be $minDurationMinutes–$maxDurationMinutes minutes';
    }
    if (mode == RadioMode.radio2 && primary != null && p.overlaps(primary)) {
      return 'radio2 must not overlap the live preset '
          '(${primary.label}) — use a different frequency';
    }
    return null;
  }

  RadioPlan copyWith(
          {RadioMode? mode, LoRaPreset? preset, int? durationMinutes}) =>
      RadioPlan(
        mode: mode ?? this.mode,
        preset: preset ?? this.preset,
        durationMinutes: durationMinutes ?? this.durationMinutes,
      );

  /// Distance in 1 MHz steps, in a fixed order, used to find a frequency that
  /// leaves the live band. Positive first so the usual direction is up.
  static const _steps = [1, 2, 3, 5, 8, 12, -1, -2, -3, -5, -8, -12];

  /// Suggest a temporary private preset near [current]: the same bandwidth,
  /// spreading factor and coding rate, a frequency far enough away that no
  /// live traffic can hear it.
  static LoRaPreset suggestTempRadio(LoRaPreset current) {
    for (final step in _steps) {
      final hz = current.frequencyHz + step * 1000000;
      if (hz < 150000000 || hz > 2500000000) continue;
      final candidate = current.copyWith(frequencyHz: hz);
      if (!candidate.overlaps(current)) return candidate;
    }
    // The whole 150–2500 MHz range is occupied by the current band only in
    // theory; fall back to the current preset rather than throwing.
    return current.copyWith(frequencyHz: current.frequencyHz + 1000000);
  }

  /// Suggest a radio2 preset. It must clear the live band with room for the
  /// radio2 guard, so the first step that does not overlap is chosen.
  static LoRaPreset suggestRadio2(LoRaPreset primary) =>
      suggestTempRadio(primary);

  /// How long to keep a temporary preset for a transfer. [estimatedSeconds]
  /// is the app's airtime estimate; a margin covers the arm, verification,
  /// retries and a slow mesh round trip.
  static int suggestDurationMinutes(
    int? estimatedSeconds, {
    int marginSeconds = 240,
  }) {
    if (estimatedSeconds == null || estimatedSeconds <= 0) {
      return defaultDurationMinutes;
    }
    final total = estimatedSeconds + marginSeconds;
    final minutes = (total / 60).ceil();
    return minutes.clamp(minDurationMinutes, maxDurationMinutes);
  }

  /// The preset to restore the companion to after the transfer: the live
  /// preset it was on before the plan moved it.
  static LoRaPreset restorePreset(LoRaPreset live) => live;
}
