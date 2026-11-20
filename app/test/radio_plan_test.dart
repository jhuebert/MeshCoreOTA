import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_repeater_manager/services/radio_plan.dart';

const _mesh = LoRaPreset(
  frequencyHz: 910525000,
  bandwidthHz: 62500,
  spreadingFactor: 7,
  codingRate: 5,
);

void main() {
  group('LoRaPreset', () {
    test('parses a firmware get radio reply', () {
      final preset = LoRaPreset.parse('> 910.525,62.5,7,5');
      expect(preset, isNotNull);
      expect(preset!.frequencyHz, 910525000);
      expect(preset.bandwidthHz, 62500);
      expect(preset.spreadingFactor, 7);
      expect(preset.codingRate, 5);
    });

    test('parses a bare argument list and rejects non-presets', () {
      expect(LoRaPreset.parse('915,125,10,5'), isNotNull);
      expect(LoRaPreset.parse(''), isNull);
      expect(LoRaPreset.parse('915,125,10'), isNull);
      expect(LoRaPreset.parse('915,125,sf,5'), isNull);
    });

    test('formats the CLI argument without trailing zeros', () {
      expect(_mesh.cli, '910.525,62.5,7,5');
      expect(
        _mesh.copyWith(bandwidthHz: 125000).cli,
        '910.525,125,7,5',
      );
      expect(
        _mesh.copyWith(frequencyHz: 915000000).cli,
        '915,62.5,7,5',
      );
    });

    test('prints a human label', () {
      expect(_mesh.label, '910.525 MHz · 62.5 kHz · SF7 · CR4/5');
    });

    test('overlap is half of each bandwidth plus the 6 kHz guard', () {
      expect(_mesh.overlaps(_mesh), isTrue);
      // Reach is (31.25 + 31.25) + 6 = 68.5 kHz either side.
      expect(_mesh.overlaps(_mesh.copyWith(frequencyHz: 910550000)), isTrue);
      expect(_mesh.overlaps(_mesh.copyWith(frequencyHz: 910625000)), isFalse);
      // Bandwidth counts too.
      expect(
        _mesh.copyWith(bandwidthHz: 250000).overlaps(
              _mesh.copyWith(frequencyHz: 910800000, bandwidthHz: 250000),
            ),
        isFalse,
      );
    });

    test('range validation matches the firmware limits', () {
      expect(_mesh.rangeError, isNull);
      expect(_mesh.copyWith(frequencyHz: 100000000).rangeError,
          contains('150 to 2500'));
      expect(_mesh.copyWith(frequencyHz: 2600000000).rangeError,
          contains('150 to 2500'));
      expect(
          _mesh.copyWith(bandwidthHz: 1000).rangeError, contains('7 to 500'));
      expect(
          _mesh.copyWith(spreadingFactor: 4).rangeError, contains('5 to 12'));
      expect(_mesh.copyWith(codingRate: 9).rangeError, contains('4/5 to 4/8'));
    });
  });

  group('RadioPlan', () {
    test('live mesh needs no preset and no zero-hop', () {
      const plan = RadioPlan();
      expect(plan.mode, RadioMode.liveMesh);
      expect(plan.requiresZeroHop, isFalse);
      expect(plan.usesRadio, isFalse);
      expect(plan.error(), isNull);
    });

    test('off-mesh modes are zero-hop and build the CLI commands', () {
      final plan = RadioPlan(
        mode: RadioMode.tempRadio,
        preset: _mesh.copyWith(frequencyHz: 914000000),
      );
      expect(plan.requiresZeroHop, isTrue);
      expect(plan.usesRadio, isTrue);
      expect(plan.error(primary: _mesh), isNull);
      expect(plan.tempRadioCommand,
          'tempradio 914,62.5,7,5,${RadioPlan.tempRadioChunkMinutes}');
      expect(plan.radio2Command, 'radio2 914,62.5,7,5');
    });

    test('a missing preset is refused', () {
      const plan = RadioPlan(mode: RadioMode.tempRadio);
      expect(plan.error(), contains('choose the radio settings'));
    });

    test('radio2 must not overlap the live preset', () {
      final overlapping = RadioPlan(
          mode: RadioMode.radio2,
          preset: _mesh.copyWith(frequencyHz: 910550000));
      expect(overlapping.error(primary: _mesh), contains('overlap'));

      final clear = RadioPlan(
          mode: RadioMode.radio2,
          preset: _mesh.copyWith(frequencyHz: 914000000));
      expect(clear.error(primary: _mesh), isNull);
    });

    test('copyWith replaces one field at a time', () {
      const original = RadioPlan();
      final changed = original.copyWith(mode: RadioMode.radio2);
      expect(changed.mode, RadioMode.radio2);
      expect(changed.preset, original.preset);
    });

    test('suggested presets leave the live band and stay in range', () {
      final temp = RadioPlan.suggestTempRadio(_mesh);
      expect(temp.rangeError, isNull);
      expect(temp.overlaps(_mesh), isFalse);
      expect(temp.frequencyHz, greaterThan(_mesh.frequencyHz));

      final radio2 = RadioPlan.suggestRadio2(_mesh);
      expect(radio2.overlaps(_mesh), isFalse);
      expect(radio2.bandwidthHz, _mesh.bandwidthHz);

      // At the top of the band the positive steps are invalid; a negative
      // step is used instead.
      final high = LoRaPreset(
        frequencyHz: 2499000000,
        bandwidthHz: 125000,
        spreadingFactor: 7,
        codingRate: 5,
      );
      final nearTop = RadioPlan.suggestTempRadio(high);
      expect(nearTop.rangeError, isNull);
      expect(nearTop.frequencyHz, lessThanOrEqualTo(2500000000));
      expect(nearTop.overlaps(high), isFalse);
    });

    test('tempradio chunks are fixed and renewed before expiry', () {
      expect(RadioPlan.tempRadioChunkMinutes, 15);
      expect(RadioPlan.tempRadioRenewAfterMinutes, 10);
      expect(RadioPlan.tempRadioRenewAfterMinutes,
          lessThan(RadioPlan.tempRadioChunkMinutes));
      expect(
          RadioPlan.shouldRenewTempRadio(const Duration(minutes: 9)), isFalse);
      expect(
          RadioPlan.shouldRenewTempRadio(const Duration(minutes: 10)), isTrue);
      expect(
          RadioPlan.shouldRenewTempRadio(const Duration(minutes: 30)), isTrue);
    });

    test('restore preset is the live preset', () {
      expect(RadioPlan.restorePreset(_mesh), same(_mesh));
    });

    test('each mode has an estimate factor', () {
      expect(const RadioPlan().estimateFactor, 1.0);
      expect(
        RadioPlan(mode: RadioMode.tempRadio, preset: _mesh).estimateFactor,
        1.0,
      );
      expect(
        RadioPlan(mode: RadioMode.radio2, preset: _mesh).estimateFactor,
        RadioPlan.radio2DutyFactor,
      );
      expect(RadioPlan.radio2DutyFactor, greaterThan(1.0));
    });

    test('estimates read as seconds or minutes', () {
      expect(RadioPlan.describeSeconds(null), 'unknown');
      expect(RadioPlan.describeSeconds(0), 'unknown');
      expect(RadioPlan.describeSeconds(45), '~45s');
      expect(RadioPlan.describeSeconds(119), '~119s');
      expect(RadioPlan.describeSeconds(120), '~2 min');
      expect(RadioPlan.describeSeconds(601), '~11 min');
    });
  });
}
