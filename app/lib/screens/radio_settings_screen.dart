import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/radio_plan.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';

/// Step 5 (detail): where the transfer runs.
///
/// The live mesh stays untouched in a temporary-preset or radio2 transfer;
/// both are zero-hop because nothing else is tuned there. The screen suggests
/// a preset and a duration from the node's own radio settings and the
/// transfer estimate, and explains what will be changed and restored.
class RadioSettingsScreen extends StatefulWidget {
  const RadioSettingsScreen({super.key});

  @override
  State<RadioSettingsScreen> createState() => _RadioSettingsScreenState();
}

class _RadioSettingsScreenState extends State<RadioSettingsScreen> {
  static const _bandwidths = <int>[
    7800,
    10400,
    15600,
    20800,
    31250,
    41700,
    62500,
    125000,
    250000,
    500000,
  ];

  late RadioMode _mode;
  late final TextEditingController _frequency;
  late final TextEditingController _duration;
  late int _bandwidthHz;
  late int _spreadingFactor;
  late int _codingRate;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _mode = app.radioPlan.mode;
    final suggested =
        app.radioPlan.preset ?? app.suggestedRadioPreset() ?? app.livePreset;
    _frequency = TextEditingController(
        text: suggested == null ? '' : _fmt(suggested.frequencyMhz));
    _duration =
        TextEditingController(text: app.radioPlan.durationMinutes.toString());
    _bandwidthHz = suggested?.bandwidthHz ?? 125000;
    _spreadingFactor = suggested?.spreadingFactor ?? 7;
    _codingRate = suggested?.codingRate ?? 5;
  }

  @override
  void dispose() {
    _frequency.dispose();
    _duration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final live = app.livePreset;
    final plan = _planFromFields();
    final problem = plan.error(primary: live);
    final fieldPreset = _presetFromFields();
    final liveEta = live == null ? null : app.estimateSecondsForPreset(live);
    final tempEta = app.estimateSecondsForPreset(fieldPreset);
    final radio2Eta = app.estimateSecondsForPreset(fieldPreset,
        factor: RadioPlan.radio2DutyFactor);
    int? etaFor(RadioMode mode) => switch (mode) {
          RadioMode.liveMesh => liveEta,
          RadioMode.tempRadio => tempEta,
          RadioMode.radio2 => radio2Eta,
        };
    final selectedEta = etaFor(_mode);

    return Scaffold(
      appBar: AppBar(title: const Text('Radio for the transfer')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const WizardBar(step: 5, label: 'Radio for the transfer'),
          const SectionHeader('Where the update runs'),
          RadioGroup<RadioMode>(
            groupValue: _mode,
            onChanged: (value) => setState(() => _mode = value ?? _mode),
            child: Column(
              children: [
                _modeTile(
                  RadioMode.liveMesh,
                  'Live mesh',
                  live == null
                      ? 'Use the normal mesh channel and the route the companion has.'
                      : 'Normal mesh channel (${live.label}) and the saved DIRECT route.',
                  liveEta,
                ),
                _modeTile(
                  RadioMode.tempRadio,
                  'Temporary private channel',
                  'Move the repeater and the companion to a private preset for the '
                      'transfer, then put both back. Zero-hop: no relay is there.',
                  tempEta,
                ),
                _modeTile(
                  RadioMode.radio2,
                  'The repeater\'s second preset',
                  'Keep the live mesh on its channel and send the transfer on the '
                      'repeater\'s radio2 preset. Zero-hop on the secondary. '
                      'About ${RadioPlan.radio2DutyFactor.toStringAsFixed(0)}× the airtime: '
                      'the repeater shares the radio with the live mesh.',
                  radio2Eta,
                ),
              ],
            ),
          ),
          if (_mode != RadioMode.liveMesh) ...[
            const SectionHeader('Private preset'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (live != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            'Live preset: ${live.label}. The private preset must '
                            'stay clear of it${_mode == RadioMode.radio2 ? ' (radio2 requires a different band)' : ''}.',
                            style: const TextStyle(
                                color: OtaTheme.textMuted,
                                fontSize: 11,
                                height: 1.4),
                          ),
                        ),
                      TextField(
                        controller: _frequency,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Frequency (MHz)',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int>(
                        key: ValueKey('bw$_bandwidthHz'),
                        initialValue: _bandwidthHz,
                        decoration: const InputDecoration(
                          labelText: 'Bandwidth (kHz)',
                          isDense: true,
                        ),
                        items: [
                          for (final hz in _bandwidthItems())
                            DropdownMenuItem(
                                value: hz, child: Text(_fmt(hz / 1000))),
                        ],
                        onChanged: (v) =>
                            setState(() => _bandwidthHz = v ?? _bandwidthHz),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              key: ValueKey('sf$_spreadingFactor'),
                              initialValue: _spreadingFactor,
                              decoration: const InputDecoration(
                                labelText: 'Spreading factor',
                                isDense: true,
                              ),
                              items: [
                                for (var sf = 5; sf <= 12; sf++)
                                  DropdownMenuItem(
                                      value: sf, child: Text('SF$sf')),
                              ],
                              onChanged: (v) =>
                                  setState(() => _spreadingFactor = v ?? 7),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              key: ValueKey('cr$_codingRate'),
                              initialValue: _codingRate,
                              decoration: const InputDecoration(
                                labelText: 'Coding rate',
                                isDense: true,
                              ),
                              items: [
                                for (var cr = 5; cr <= 8; cr++)
                                  DropdownMenuItem(
                                      value: cr, child: Text('4/$cr')),
                              ],
                              onChanged: (v) =>
                                  setState(() => _codingRate = v ?? 5),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => _suggest(app, selectedEta),
                          icon: const Icon(Icons.auto_fix_high, size: 18),
                          label: const Text('Suggest settings'),
                        ),
                      ),
                      Text(
                        'Preset: ${_presetFromFields().label}',
                        style: const TextStyle(
                            color: OtaTheme.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SectionHeader('Duration'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _duration,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Keep the preset for (minutes)',
                                isDense: true,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: OutlinedButton(
                              onPressed: selectedEta == null
                                  ? null
                                  : () => setState(() {
                                        _duration.text =
                                            RadioPlan.suggestDurationMinutes(
                                                    selectedEta)
                                                .toString();
                                      }),
                              child: Text(
                                selectedEta == null
                                    ? 'Estimate'
                                    : 'Use ${RadioPlan.suggestDurationMinutes(selectedEta)} min',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        selectedEta == null
                            ? 'Choose an image to see the transfer estimate. The '
                                'preset reverts automatically when the time is up, '
                                'on both ends.'
                            : 'Estimated transfer: ${RadioPlan.describeSeconds(selectedEta)} '
                                'for the selected radio. The preset reverts '
                                'automatically when the time is up, on both ends.',
                        style: const TextStyle(
                            color: OtaTheme.textMuted,
                            fontSize: 11,
                            height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_mode == RadioMode.radio2) _radio2Note(app),
          ],
          if (problem != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text(
                problem,
                style: const TextStyle(color: OtaTheme.bad, fontSize: 12),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'A low battery still suspends staging, and the node still '
              'verifies the image by SHA-256 before anything can boot.',
              style: TextStyle(
                  color: OtaTheme.textMuted, fontSize: 11, height: 1.45),
            ),
          ),
        ],
      ),
      bottomNavigationBar: WizardFooter(
        label: 'Use these settings',
        icon: Icons.check,
        onPressed: problem != null ? null : () => _save(app, plan),
      ),
    );
  }

  Widget _modeTile(
    RadioMode mode,
    String title,
    String subtitle,
    int? etaSeconds,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Card(
        color: _mode == mode ? OtaTheme.surfaceHigh : null,
        child: RadioListTile<RadioMode>(
          value: mode,
          title: Text(title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(subtitle,
                  style: const TextStyle(
                      color: OtaTheme.textMuted, fontSize: 11, height: 1.35)),
              const SizedBox(height: 3),
              Text(
                etaSeconds == null
                    ? 'Estimated transfer: choose an image to see'
                    : 'Estimated transfer: ${RadioPlan.describeSeconds(etaSeconds)}',
                style: TextStyle(
                  color: _mode == mode ? OtaTheme.accent : OtaTheme.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _radio2Note(AppState app) {
    final enabled = app.radio2Enabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(
        enabled == true
            ? 'radio2 is already enabled on this node. Enter the secondary '
                'preset it already uses; the app will not change the node\'s '
                'radio2 configuration and will only tune the companion to it.'
            : enabled == false
                ? 'radio2 is off. The app enables it for the update with these '
                    'settings and turns it off again afterwards.'
                : 'The node did not report a radio2 state. If radio2 is already '
                    'enabled, enter its existing secondary preset — the app will '
                    'not change it either way.',
        style: TextStyle(
          color: enabled == true ? OtaTheme.warn : OtaTheme.textMuted,
          fontSize: 11,
          height: 1.45,
        ),
      ),
    );
  }

  List<int> _bandwidthItems() {
    final values = [..._bandwidths];
    if (!values.contains(_bandwidthHz)) values.add(_bandwidthHz);
    values.sort();
    return values;
  }

  LoRaPreset _presetFromFields() {
    final mhz = double.tryParse(_frequency.text.trim()) ?? 0;
    return LoRaPreset(
      frequencyHz: (mhz * 1e6).round(),
      bandwidthHz: _bandwidthHz,
      spreadingFactor: _spreadingFactor,
      codingRate: _codingRate,
    );
  }

  RadioPlan _planFromFields() => RadioPlan(
        mode: _mode,
        preset: _mode == RadioMode.liveMesh ? null : _presetFromFields(),
        durationMinutes: int.tryParse(_duration.text.trim()) ?? 0,
      );

  void _suggest(AppState app, int? etaSeconds) {
    final suggested = app.suggestedRadioPreset() ?? app.livePreset;
    if (suggested == null) return;
    setState(() {
      _frequency.text = _fmt(suggested.frequencyMhz);
      _bandwidthHz = suggested.bandwidthHz;
      _spreadingFactor = suggested.spreadingFactor;
      _codingRate = suggested.codingRate;
      if (etaSeconds != null) {
        _duration.text =
            RadioPlan.suggestDurationMinutes(etaSeconds).toString();
      }
    });
  }

  void _save(AppState app, RadioPlan plan) {
    app.setRadioMode(_mode);
    if (_mode != RadioMode.liveMesh) {
      app.setRadioPreset(_presetFromFields());
      app.setRadioDuration(plan.durationMinutes);
    }
    Navigator.of(context).pop();
  }

  static String _fmt(double value) {
    var text = value.toStringAsFixed(3);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
    return text;
  }
}
