// Declarative description of the settings a repeater can change remotely.
// One registry feeds the curated screens, the generic browser and fleet bulk
// scripts, so validation and formatting stay identical in all three.

enum SettingInput { toggle, number, text, choice, preset }

class SettingSpec {
  const SettingSpec({
    required this.key,
    required this.label,
    required this.section,
    required this.input,
    this.min,
    this.max,
    this.choices,
    this.secret = false,
    this.help = '',
  });

  final String key;
  final String label;
  final String section;
  final SettingInput input;
  final num? min;
  final num? max;
  final List<String>? choices;
  final bool secret;
  final String help;

  /// Returns an error message, or null when [value] can be sent as-is.
  String? validate(String value) {
    final text = value.trim();
    if (text.isEmpty) return 'Enter a value';
    if (secret && text.contains(RegExp(r'\s'))) {
      return 'Passwords cannot contain spaces';
    }
    switch (input) {
      case SettingInput.toggle:
        final v = text.toLowerCase();
        return (v == 'on' || v == 'off') ? null : 'Use on or off';
      case SettingInput.number:
        final number = num.tryParse(text);
        if (number == null) return 'Enter a number';
        if (min != null && number < min!) return 'Must be at least $min';
        if (max != null && number > max!) return 'Must be at most $max';
        return null;
      case SettingInput.choice:
        return choices != null && choices!.contains(text)
            ? null
            : 'Choose one of ${choices!.join(', ')}';
      case SettingInput.preset:
        // f,bw,sf,cr as used by `get radio` and `set radio`.
        final parts = text.split(',');
        if (parts.length != 4 || parts.any((p) => p.trim().isEmpty)) {
          return 'Use frequency,bandwidth,sf,cr';
        }
        return null;
      case SettingInput.text:
        return null;
    }
  }
}

/// Remote settings from the stock CLI. Serial-only keys and keys with no
/// firmware handler (`radio.fem.*`) are deliberately absent.
const stockSettings = <SettingSpec>[
  SettingSpec(
      key: 'name',
      label: 'Name',
      section: 'Basic',
      input: SettingInput.text),
  SettingSpec(
      key: 'lat',
      label: 'Latitude',
      section: 'Basic',
      input: SettingInput.number,
      min: -90,
      max: 90),
  SettingSpec(
      key: 'lon',
      label: 'Longitude',
      section: 'Basic',
      input: SettingInput.number,
      min: -180,
      max: 180),
  SettingSpec(
      key: 'owner.info',
      label: 'Owner info',
      section: 'Basic',
      input: SettingInput.text),
  SettingSpec(
      key: 'guest.password',
      label: 'Guest password',
      section: 'Basic',
      input: SettingInput.text,
      secret: true),
  SettingSpec(
      key: 'allow.read.only',
      label: 'Allow read only',
      section: 'Basic',
      input: SettingInput.toggle),
  SettingSpec(
      key: 'radio',
      label: 'Radio preset',
      section: 'Radio',
      input: SettingInput.preset,
      help: 'Frequency in MHz, bandwidth in kHz, then SF and CR.'),
  SettingSpec(
      key: 'tx',
      label: 'Transmit power (dBm)',
      section: 'Radio',
      input: SettingInput.number,
      min: 0,
      max: 30),
  SettingSpec(
      key: 'af',
      label: 'Adaptive frequency',
      section: 'Radio',
      input: SettingInput.toggle),
  SettingSpec(
      key: 'dutycycle',
      label: 'Duty cycle (%)',
      section: 'Radio',
      input: SettingInput.number,
      min: 0,
      max: 100),
  SettingSpec(
      key: 'cad',
      label: 'Channel activity detection',
      section: 'Radio',
      input: SettingInput.toggle),
  SettingSpec(
      key: 'radio.rxgain',
      label: 'RX gain',
      section: 'Radio',
      input: SettingInput.number),
  SettingSpec(
      key: 'rxdelay',
      label: 'RX delay (ms)',
      section: 'Radio',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'agc.reset.interval',
      label: 'AGC reset interval',
      section: 'Radio',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'int.thresh',
      label: 'Interrupt threshold',
      section: 'Radio',
      input: SettingInput.number),
  SettingSpec(
      key: 'repeat',
      label: 'Repeat messages',
      section: 'Features',
      input: SettingInput.toggle),
  SettingSpec(
      key: 'loop.detect',
      label: 'Loop detection',
      section: 'Features',
      input: SettingInput.toggle),
  SettingSpec(
      key: 'multi.acks',
      label: 'Multiple ACKs',
      section: 'Features',
      input: SettingInput.toggle),
  SettingSpec(
      key: 'flood.max',
      label: 'Flood limit',
      section: 'Network health',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'flood.max.unscoped',
      label: 'Unscoped flood limit',
      section: 'Network health',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'flood.max.advert',
      label: 'Advert flood limit',
      section: 'Network health',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'path.hash.mode',
      label: 'Path hash mode',
      section: 'Network health',
      input: SettingInput.number,
      min: 0,
      max: 3),
  SettingSpec(
      key: 'txdelay',
      label: 'TX delay (ms)',
      section: 'Timing',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'direct.txdelay',
      label: 'Direct TX delay (ms)',
      section: 'Timing',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'flood.advert.interval',
      label: 'Flood advert interval',
      section: 'Timing',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'advert.interval',
      label: 'Advert interval',
      section: 'Timing',
      input: SettingInput.number,
      min: 0),
  SettingSpec(
      key: 'adc.multiplier',
      label: 'Battery ADC multiplier',
      section: 'Advanced',
      input: SettingInput.number),
  SettingSpec(
      key: 'extra.sf',
      label: 'Extra spreading factor',
      section: 'Advanced',
      input: SettingInput.number),
];

/// The stock sections in display order.
const stockSections = <String>[
  'Basic',
  'Radio',
  'Features',
  'Network health',
  'Timing',
  'Advanced',
];

SettingSpec? settingFor(String key) {
  for (final spec in stockSettings) {
    if (spec.key == key) return spec;
  }
  return null;
}

List<SettingSpec> settingsIn(String section) =>
    stockSettings.where((s) => s.section == section).toList();
