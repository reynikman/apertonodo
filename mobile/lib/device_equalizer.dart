import 'package:just_audio/just_audio.dart';

import 'equalizer.dart';

/// Phone equalizer via `AndroidEqualizer` from just_audio.
class DeviceEqualizerPort implements EqualizerPort {
  DeviceEqualizerPort(this.equalizer);

  final AndroidEqualizer equalizer;

  AndroidEqualizerParameters? _parameters;

  @override
  Future<List<EqBand>> bands() async {
    final p = _parameters = await equalizer.parameters;
    return [
      for (final b in p.bands)
        EqBand(
          centerHz: b.centerFrequency.round(),
          minDb: p.minDecibels,
          maxDb: p.maxDecibels,
        ),
    ];
  }

  @override
  Future<void> setEnabled(bool on) => equalizer.setEnabled(on);

  @override
  Future<void> setGain(int index, double db) async {
    final p = _parameters ?? await equalizer.parameters;
    await p.bands[index].setGain(db);
  }
}
