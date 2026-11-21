import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  test('the registry covers the remote-only stock keys', () {
    expect(settingFor('radio')!.input, SettingInput.preset);
    expect(settingFor('repeat')!.input, SettingInput.toggle);
    expect(settingFor('guest.password')!.secret, isTrue);
    // Serial-only and non-existent firmware keys are not manageable remotely.
    expect(settingFor('prv.key'), isNull);
    expect(settingFor('radio.fem.txgain'), isNull);
    expect(settingsIn('Radio').map((s) => s.key), contains('dutycycle'));
  });

  test('numeric keys validate their range', () {
    expect(settingFor('tx')!.validate('20'), isNull);
    expect(settingFor('tx')!.validate('40'), contains('at most'));
    expect(settingFor('lat')!.validate('-91'), contains('at least'));
    expect(settingFor('tx')!.validate('high'), contains('number'));
  });

  test('toggle, choice and preset keys validate their shape', () {
    expect(settingFor('repeat')!.validate('on'), isNull);
    expect(settingFor('repeat')!.validate('yes'), contains('on or off'));
    expect(settingFor('radio')!.validate('915.0,250,10,5'), isNull);
    expect(settingFor('radio')!.validate('915,250'), contains('frequency'));
    expect(settingFor('guest.password')!.validate('two words'),
        contains('spaces'));
  });
}
