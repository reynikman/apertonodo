import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../equalizer.dart';
import '../l10n/l10n.dart';
import '../theme.dart';

class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key, required this.equalizer});

  final Equalizer equalizer;

  static String _hz(AppLocalizations t, int hz) {
    if (hz < 1000) return t.equalizerHz('$hz');
    final f = NumberFormat.decimalPattern(t.localeName)
      ..maximumFractionDigits = 1;
    return t.equalizerKhz(f.format(hz / 1000));
  }

  @override
  Widget build(BuildContext context) {
    final t = l10n(context);
    final presets = {
      'flat': t.equalizerFlat,
      'bass': t.equalizerBass,
      'treble': t.equalizerTreble,
      'vocal': t.equalizerVocal,
    };
    return Scaffold(
      key: const Key('equalizer-window'),
      appBar: AppBar(title: Text(t.equalizerTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: equalizer,
          builder: (context, _) {
            if (equalizer.loading) {
              return _Message(key: const Key('eq-waiting'), t.equalizerWaiting);
            }
            if (!equalizer.available) {
              return _Message(t.equalizerMissing);
            }
            final on = equalizer.enabled;
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const Key('eq-enabled'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      t.equalizerTitle,
                      style: ApertonoText.trackTitle,
                    ),
                    value: on,
                    onChanged: equalizer.setEnabled,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final e in presets.entries)
                        SizedBox(
                          key: Key('eq-preset-${e.key}'),
                          height: 48,
                          child: ChoiceChip(
                            label: Text(e.value),
                            selected: equalizer.preset == e.key,
                            onSelected: (_) => equalizer.choose(e.key),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < equalizer.bands.length; i++)
                    Row(
                      children: [
                        SizedBox(
                          width: 72,
                          child: Text(
                            _hz(t, equalizer.bands[i].centerHz),
                            style: ApertonoText.trackArtist,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            key: Key('eq-band-$i'),
                            min: equalizer.bands[i].minDb,
                            max: equalizer.bands[i].maxDb,
                            value: equalizer.gains[i],
                            onChanged: on
                                ? (v) => equalizer.setGain(i, v)
                                : null,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: ApertonoText.trackArtist,
      ),
    ),
  );
}
