import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/equalizer.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/equalizer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FT-621 (P-A77, "sound" group): equalizer. User boosts bass or
/// voice, selection survives relaunch, on phone without equalizer screen
/// honestly states that it is unavailable.
///
/// Bands and ranges are defined by phone (typically 5 bands, ±15 dB), so
/// presets are defined by frequencies and mapped onto available bands.
///
/// What tests do not prove: that sound on real phone actually changes — that is
/// `AndroidEqualizer` inside ExoPlayer, verified by owner by ear after
/// button wiring.
class FakeEqualizerPort implements EqualizerPort {
  FakeEqualizerPort({List<EqBand>? bands, this.ready})
    : _bands = bands ?? fiveBands;

  final List<EqBand> _bands;

  /// Not `null` — bands appear when completed (on phone they
  /// are known only after first song).
  final Completer<void>? ready;

  bool? enabled;
  final Map<int, double> gains = {};
  bool broken = false;

  @override
  Future<List<EqBand>> bands() async {
    if (broken) throw StateError('no equalizer on this phone');
    await ready?.future;
    return _bands;
  }

  @override
  Future<void> setEnabled(bool on) async => enabled = on;

  @override
  Future<void> setGain(int index, double db) async => gains[index] = db;
}

const fiveBands = [
  EqBand(centerHz: 60, minDb: -15, maxDb: 15),
  EqBand(centerHz: 230, minDb: -15, maxDb: 15),
  EqBand(centerHz: 910, minDb: -15, maxDb: 15),
  EqBand(centerHz: 3600, minDb: -15, maxDb: 15),
  EqBand(centerHz: 14000, minDb: -15, maxDb: 15),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Equalizer> loaded(FakeEqualizerPort port) async {
    final eq = Equalizer(port: port);
    addTearDown(eq.dispose);
    await eq.load();
    return eq;
  }

  test('presets map onto phone equalizer bands', () async {
    final port = FakeEqualizerPort();
    final eq = await loaded(port);
    expect(eq.available, isTrue);
    expect(eq.bands, fiveBands);

    await eq.choose('flat');
    expect(eq.gains, everyElement(0.0));

    await eq.choose('bass');
    expect(eq.preset, 'bass');
    expect(eq.gains.first, greaterThanOrEqualTo(4));
    expect(eq.gains.last, 0.0, reason: 'bass does not affect highs');
    expect(port.gains[0], eq.gains[0], reason: 'band pushed to phone');

    await eq.choose('treble');
    expect(eq.gains.last, greaterThanOrEqualTo(4));
    expect(eq.gains.first, 0.0);

    await eq.choose('vocal');
    expect(
      eq.gains[2],
      greaterThan(eq.gains.first),
      reason: 'mid frequencies higher than bass',
    );
  });

  test('preset stays within limits of phone bands', () async {
    final narrow = [
      for (final b in fiveBands)
        EqBand(centerHz: b.centerHz, minDb: -3, maxDb: 3),
    ];
    final eq = await loaded(FakeEqualizerPort(bands: narrow));
    await eq.choose('bass');
    expect(eq.gains.first, 3.0);
    for (final g in eq.gains) {
      expect(g, inInclusiveRange(-3, 3));
    }
  });

  test('slider creates custom preset with bounded value', () async {
    final port = FakeEqualizerPort();
    final eq = await loaded(port);
    await eq.choose('bass');
    await eq.setGain(4, 40);
    expect(eq.preset, 'custom');
    expect(eq.gains[4], 15.0);
    expect(port.gains[4], 15.0);
  });

  test('disabled: sound flat, settings retained', () async {
    final port = FakeEqualizerPort();
    final eq = await loaded(port);
    await eq.setEnabled(true);
    await eq.choose('bass');
    expect(port.enabled, isTrue);
    final before = List.of(eq.gains);

    await eq.setEnabled(false);
    expect(port.enabled, isFalse);
    expect(eq.enabled, isFalse);
    expect(eq.gains, before, reason: 're-enabled: same bass gains');
  });

  test('selection survives restart', () async {
    final first = await loaded(FakeEqualizerPort());
    await first.setEnabled(true);
    await first.choose('bass');
    await first.setGain(2, -5);
    final saved = List.of(first.gains);

    final port = FakeEqualizerPort();
    final again = await loaded(port);
    expect(again.enabled, isTrue);
    expect(again.preset, 'custom');
    expect(again.gains, saved);
    expect(port.enabled, isTrue, reason: 'phone told to enable');
    for (var i = 0; i < saved.length; i++) {
      expect(port.gains[i], saved[i], reason: 'band $i pushed to phone');
    }
  });

  test('disabled and flat by default', () async {
    final port = FakeEqualizerPort();
    final eq = await loaded(port);
    expect(eq.enabled, isFalse);
    expect(eq.preset, 'flat');
    expect(port.enabled, isNot(isTrue));
  });

  test('different phone with other bands: flat, no crash', () async {
    final first = await loaded(FakeEqualizerPort());
    await first.setEnabled(true);
    await first.setGain(0, 7);

    final three = [
      const EqBand(centerHz: 100, minDb: -12, maxDb: 12),
      const EqBand(centerHz: 1000, minDb: -12, maxDb: 12),
      const EqBand(centerHz: 10000, minDb: -12, maxDb: 12),
    ];
    final eq = await loaded(FakeEqualizerPort(bands: three));
    expect(eq.gains, hasLength(3));
    expect(eq.gains, everyElement(0.0));
    expect(eq.enabled, isTrue);
  });

  test('corrupted storage does not crash equalizer', () async {
    SharedPreferences.setMockInitialValues({'eq-gains': 'не список'});
    final eq = await loaded(FakeEqualizerPort());
    expect(eq.available, isTrue);
    expect(eq.preset, 'flat');
  });

  test('phone without equalizer', () async {
    final eq = await loaded(FakeEqualizerPort()..broken = true);
    expect(eq.available, isFalse);
    await eq.choose('bass');
    await eq.setEnabled(true);
  });

  test('screen notified on every change', () async {
    final eq = await loaded(FakeEqualizerPort());
    var heard = 0;
    eq.addListener(() => heard++);
    await eq.setEnabled(true);
    await eq.choose('bass');
    await eq.setGain(1, 2);
    expect(heard, greaterThanOrEqualTo(3));
  });

  for (final (locale, bassLabel, hz, khz, missing) in [
    (
      const Locale('ru'),
      'Басы',
      '60 Гц',
      '3,6 кГц',
      'На этом телефоне эквалайзера нет',
    ),
    (
      const Locale('en'),
      'Bass',
      '60 Hz',
      '3.6 kHz',
      'This phone has no equalizer',
    ),
  ]) {
    Widget screen(Equalizer eq) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: EqualizerScreen(equalizer: eq),
    );

    testWidgets('screen - $locale', (tester) async {
      final port = FakeEqualizerPort();
      final eq = Equalizer(port: port);
      addTearDown(eq.dispose);
      await tester.runAsync(eq.load);
      await tester.pumpWidget(screen(eq));
      await tester.pump();

      expect(find.text(hz), findsOneWidget);
      expect(find.text(khz), findsOneWidget);
      for (final id in ['flat', 'bass', 'treble', 'vocal']) {
        final chip = find.byKey(Key('eq-preset-$id'));
        expect(chip, findsOneWidget, reason: id);
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
      }
      expect(find.text(bassLabel), findsOneWidget);
      for (var i = 0; i < 5; i++) {
        expect(find.byKey(Key('eq-band-$i')), findsOneWidget);
      }
      Slider slider(int i) =>
          tester.widget<Slider>(find.byKey(Key('eq-band-$i')));
      expect(slider(0).onChanged, isNull, reason: 'disabled - sliders idle');

      await tester.tap(find.byKey(const Key('eq-enabled')));
      await tester.pump();
      expect(eq.enabled, isTrue);
      expect(slider(0).onChanged, isNotNull);

      await tester.tap(find.byKey(const Key('eq-preset-bass')));
      await tester.pump();
      expect(eq.preset, 'bass');
      expect(slider(0).value, eq.gains[0]);
    });

    testWidgets('screen without equalizer - $locale', (tester) async {
      final eq = Equalizer(port: FakeEqualizerPort()..broken = true);
      addTearDown(eq.dispose);
      await tester.runAsync(eq.load);
      await tester.pumpWidget(screen(eq));
      await tester.pump();
      expect(find.text(missing), findsOneWidget);
      expect(find.byKey(const Key('eq-band-0')), findsNothing);
      expect(find.byKey(const Key('eq-enabled')), findsNothing);
    });

    testWidgets('bands unknown yet: waiting for first track - $locale', (
      tester,
    ) async {
      final ready = Completer<void>();
      final eq = Equalizer(port: FakeEqualizerPort(ready: ready));
      addTearDown(eq.dispose);
      final loading = eq.load();
      await tester.pumpWidget(screen(eq));
      await tester.pump();
      expect(find.byKey(const Key('eq-waiting')), findsOneWidget);
      expect(find.byKey(const Key('eq-band-0')), findsNothing);

      ready.complete();
      await tester.runAsync(() => loading);
      await tester.pump();
      expect(find.byKey(const Key('eq-waiting')), findsNothing);
      expect(find.byKey(const Key('eq-band-0')), findsOneWidget);
    });
  }
}
