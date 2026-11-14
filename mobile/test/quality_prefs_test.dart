// FT-633 (P-A94): audio quality selection — three modes, selection sheet, and format badge.
//
// Currently app decides automatically: requests compressed copy on metered networks, raw file otherwise.
// Users with unlimited cellular data or expensive Wi-Fi cannot override this.
//
// Guarded:
// - "Auto" behaves as today; "Always save data" and "Lossless only" ignore network type completely;
// - selection persists on device across restarts; corrupted storage or errors fallback to "Auto";
// - sheet: three explained rows, selected item checked; Russian and English; touch target >= 48 dp;
// - format badge displays known formats only and is read aloud by screen reader.
//
// What test does not prove: mode reaching server — `preferOpus` in `main.dart` wired by lead during
// merge; "Lossless only" finding FLAC specifically — server currently only supports "no recompression",
// lossless source selection is separate backend card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/quality_prefs.dart';
import 'package:music_stream/screens/format_badge.dart';
import 'package:music_stream/screens/quality_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<QualityPrefs> _loaded() async {
  final prefs = QualityPrefs();
  addTearDown(prefs.dispose);
  await prefs.load();
  return prefs;
}

Widget _app(Widget child, [Locale locale = const Locale('ru')]) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('default \'Auto\': network decides', () async {
    final prefs = await _loaded();
    expect(prefs.mode, QualityMode.auto);
    expect(await prefs.preferOpus(() async => true), isTrue);
    expect(await prefs.preferOpus(() async => false), isFalse);
  });

  test('\'Always saving\' and \'Lossless\' skip network check', () async {
    final prefs = await _loaded();
    var asked = 0;
    Future<bool> metered() async {
      asked++;
      return false;
    }

    await prefs.setMode(QualityMode.economy);
    expect(await prefs.preferOpus(metered), isTrue);
    await prefs.setMode(QualityMode.lossless);
    expect(
      await prefs.preferOpus(() async {
        asked++;
        return true;
      }),
      isFalse,
    );
    expect(asked, 0);
  });

  test('\'Auto\': network unresponsive - save data', () async {
    final prefs = await _loaded();
    expect(
      await prefs.preferOpus(() => Future.error(StateError('no channel'))),
      isTrue,
      reason: 'as DeviceInfo.isMetered: unknown network treated as metered',
    );
  });

  test('selection survives restart and notifies listeners', () async {
    final prefs = await _loaded();
    var heard = 0;
    prefs.addListener(() => heard++);
    await prefs.setMode(QualityMode.lossless);
    expect(prefs.mode, QualityMode.lossless);
    expect(heard, 1);
    await prefs.setMode(QualityMode.lossless);
    expect(heard, 1, reason: 'same mode is no change');

    final restarted = await _loaded();
    expect(restarted.mode, QualityMode.lossless);
    final stored = await SharedPreferences.getInstance();
    expect(stored.getString('quality-mode'), 'lossless');
  });

  test('corrupted storage defaults to \'Auto\'', () async {
    for (final Map<String, Object> junk in [
      {'quality-mode': 'ultra'},
      {'quality-mode': ''},
      {'quality-mode': 7},
    ]) {
      SharedPreferences.setMockInitialValues(junk);
      final prefs = await _loaded();
      expect(prefs.mode, QualityMode.auto, reason: '$junk');
    }
  });

  for (final (locale, title, rows) in [
    (
      const Locale('ru'),
      'Качество звука',
      [
        ('auto', 'Авто', 'По Wi-Fi — как есть, по мобильной сети — экономно'),
        ('economy', 'Всегда экономно', 'Меньше трафика на любой сети'),
        (
          'lossless',
          'Только без потерь',
          'FLAC, если он есть. Нет — сыграет то, что есть',
        ),
      ],
    ),
    (
      const Locale('en'),
      'Sound quality',
      [
        ('auto', 'Auto', 'Original on Wi-Fi, data saver on mobile data'),
        ('economy', 'Always data saver', 'Less data on any network'),
        (
          'lossless',
          'Lossless only',
          'FLAC when available. Otherwise plays what there is',
        ),
      ],
    ),
  ]) {
    testWidgets('selection sheet - $locale', (tester) async {
      final prefs = await tester.runAsync(_loaded) as QualityPrefs;
      await tester.pumpWidget(_app(QualitySheet(prefs: prefs), locale));

      expect(find.text(title), findsOneWidget);
      for (final (id, name, hint) in rows) {
        final row = find.byKey(Key('quality-$id'));
        expect(row, findsOneWidget, reason: id);
        expect(
          find.descendant(of: row, matching: find.text(name)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text(hint)),
          findsOneWidget,
        );
        expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      }
      Finder checkIn(String id) => find.descendant(
        of: find.byKey(Key('quality-$id')),
        matching: find.byKey(const Key('quality-check')),
      );
      expect(find.byKey(const Key('quality-check')), findsOneWidget);
      expect(checkIn('auto'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('quality-lossless')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(prefs.mode, QualityMode.lossless);
      expect(find.byKey(const Key('quality-check')), findsOneWidget);
      expect(checkIn('lossless'), findsOneWidget);
    });
  }

  testWidgets('format badge: shows known, hides others', (tester) async {
    for (final (format, label) in [
      ('flac', 'FLAC'),
      ('FLAC', 'FLAC'),
      ('mp3', 'MP3'),
      ('opus', 'OPUS'),
      ('aac', 'AAC'),
      ('ogg', 'OGG'),
      (' m4a ', 'M4A'),
    ]) {
      await tester.pumpWidget(_app(FormatBadge(format: format)));
      expect(find.text(label), findsOneWidget, reason: format);
    }
    for (final format in [
      null,
      '',
      '   ',
      'torrent',
      'magnet:?xt=1',
      'x' * 40,
    ]) {
      await tester.pumpWidget(_app(FormatBadge(format: format)));
      expect(find.byType(Text), findsNothing, reason: '$format');
    }
  });

  for (final (locale, spoken) in [
    (const Locale('ru'), 'Формат: FLAC'),
    (const Locale('en'), 'Format: FLAC'),
  ]) {
    testWidgets('format badge read aloud - $locale', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(const FormatBadge(format: 'flac'), locale));
      expect(find.bySemanticsLabel(spoken), findsOneWidget);
      handle.dispose();
    });
  }
}
