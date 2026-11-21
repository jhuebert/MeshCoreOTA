import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  group('classifyProbe', () {
    test('stock negative signatures', () {
      expect(classifyProbe('filter', 'Unknown command'),
          ProbeVerdict.stockNegative);
      expect(classifyProbe('get cpu.freq', '??: cpu.freq'),
          ProbeVerdict.stockNegative);
    });

    test('fork positive signatures', () {
      expect(
          classifyProbe(
              'ota status', 'running=v1.2 sha=deadbeef state=idle'),
          ProbeVerdict.forkPositive);
      expect(classifyProbe('filter', 'Err - usage: on|off|add'),
          ProbeVerdict.forkPositive);
      expect(classifyProbe('radio2 status', 'off; preset=915,250,10,5'),
          ProbeVerdict.forkPositive);
      expect(classifyProbe('get radio.rxps', '> desired=on,effective=on'),
          ProbeVerdict.forkPositive);
    });

    test('silence and unrecognised text are unknown', () {
      expect(classifyProbe('filter', ''), ProbeVerdict.unknown);
      expect(classifyProbe('bot', 'something else'), ProbeVerdict.unknown);
    });
  });

  group('detectCapabilities', () {
    test('an unanswered probe set leaves everything unknown', () {
      final c = detectCapabilities(replies: {
        'filter': null,
        'fleet': '',
      });
      expect(c.firmwareKind, FirmwareKind.unknown);
      expect(c.confidence, CapabilityConfidence.unknown);
      expect(c.supports('filter'), isFalse);
    });

    test('a single hit is tentative', () {
      final c = detectCapabilities(replies: {'filter': 'Err - usage: on|off'});
      expect(c.firmwareKind, FirmwareKind.fork);
      expect(c.confidence, CapabilityConfidence.tentative);
      expect(c.filter, isTrue);
    });

    test('three positive probes confirm the fork and its extras', () {
      final c = detectCapabilities(replies: {
        'filter': 'Err - usage: on|off|add',
        'fleet': 'Err - usage: on|off|chan',
        'radio2 status': 'on; preset=915,250,10,5',
        'battery': 'batt 4100mV; gate off',
      });
      expect(c.firmwareKind, FirmwareKind.fork);
      expect(c.confidence, CapabilityConfidence.confirmed);
      expect(c.filter, isTrue);
      expect(c.fleet, isTrue);
      expect(c.radio2, isTrue);
      expect(c.batteryGate, isTrue);
      expect(c.mqtt, isFalse);
    });

    test('two stock negatives confirm stock', () {
      final c = detectCapabilities(replies: {
        'filter': 'Unknown command',
        'fleet': 'Unknown command',
      });
      expect(c.firmwareKind, FirmwareKind.stock);
      expect(c.confidence, CapabilityConfidence.confirmed);
      expect(c.filter, isFalse);
    });

    test('OTA confirmation is decisive on its own', () {
      final c = detectCapabilities(
          replies: {'ota status': 'running=v1 sha=aa state=idle'},
          otaConfirmed: true);
      expect(c.firmwareKind, FirmwareKind.fork);
      expect(c.confidence, CapabilityConfidence.confirmed);
      expect(c.ota, isTrue);
    });

    test('evidence and json survive a roundtrip', () {
      final c = detectCapabilities(replies: {
        'filter': 'Err - usage: on|off',
        'fleet': 'Err - usage: chan',
        'bot': 'bot: on/off, name',
      }, otaConfirmed: true);
      final copy = RepeaterCapabilities.fromJson(c.toJson());
      expect(copy.firmwareKind, c.firmwareKind);
      expect(copy.confidence, c.confidence);
      expect(copy.bot, isTrue);
      expect(copy.evidence['filter'], c.evidence['filter']);
      expect(copy.copyWithOtaFeatures(7).otaFeatures, 7);
    });
  });
}
