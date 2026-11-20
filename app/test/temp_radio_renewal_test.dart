import 'package:flutter_test/flutter_test.dart';

import 'package:meshcore_repeater_manager/services/temp_radio_renewal.dart';

void main() {
  late DateTime clock;
  late TempRadioRenewal renewal;
  late List<bool> results;

  setUp(() {
    clock = DateTime(2026, 11, 19, 12);
    renewal = TempRadioRenewal(now: () => clock);
    results = <bool>[];
  });

  Future<bool> answer(bool ok) async {
    results.add(ok);
    return ok;
  }

  test('nothing happens before the renewal threshold', () async {
    renewal.arm();
    clock = clock.add(const Duration(minutes: 9));

    expect(await renewal.maybeRenew(renew: () => answer(true)), isFalse);
    expect(results, isEmpty);
    expect(renewal.abandoned, isFalse);
  });

  test('a successful renewal restarts the chunk and clears failures', () async {
    renewal.arm();
    clock = clock.add(const Duration(minutes: 11));

    expect(await renewal.maybeRenew(renew: () => answer(true)), isTrue);
    expect(results, [true]);
    expect(renewal.failures, 0);

    // The next attempt is only due another ten minutes after the renewal.
    expect(await renewal.maybeRenew(renew: () => answer(true)), isFalse);
    clock = clock.add(const Duration(minutes: 10));
    expect(await renewal.maybeRenew(renew: () => answer(true)), isTrue);
    expect(results, [true, true]);
  });

  test('two consecutive failures mark the channel abandoned', () async {
    renewal.arm();
    clock = clock.add(const Duration(minutes: 11));

    expect(await renewal.maybeRenew(renew: () => answer(false)), isTrue);
    expect(renewal.failures, 1);
    expect(renewal.abandoned, isFalse);

    // A failed renewal does not restart the timer.
    expect(await renewal.maybeRenew(renew: () => answer(false)), isTrue);
    expect(renewal.failures, 2);
    expect(renewal.abandoned, isTrue);
  });

  test('arm and clear reset the timing and the failure count', () async {
    renewal.arm();
    clock = clock.add(const Duration(minutes: 11));
    await renewal.maybeRenew(renew: () => answer(false));
    await renewal.maybeRenew(renew: () => answer(false));
    expect(renewal.abandoned, isTrue);

    renewal.arm();
    expect(renewal.failures, 0);
    expect(renewal.abandoned, isFalse);
    expect(await renewal.maybeRenew(renew: () => answer(true)), isFalse);

    renewal.clear();
    clock = clock.add(const Duration(minutes: 30));
    expect(await renewal.maybeRenew(renew: () => answer(true)), isFalse);
  });

  test('the clock can be swapped for a test seam', () {
    final started = renewal.now;
    DateTime other() => clock.add(const Duration(hours: 1));
    renewal.now = other;
    expect(renewal.now, same(other));
    renewal.now = started;
  });
}
