// FT-692: next track prefetch — always / Wi-Fi only / never (P-A101). Lead check written before work.
//
// Contract:
// - `mayPrefetch`: always — always true; never — always false; wifiOnly — Wi-Fi and unmetered network only;
// - storage: key `prefetch_mode`, string — mode name (`always`, `wifiOnly`, `never`);
// - before `load` or on empty/unknown/non-string value — `always`; storage failure does not throw;
// - `set` with same mode — no-op (no write, no notify); different — single notify and write;
// - settings section: header, three options, subtitle for "never"; tap selects mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/prefetch_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';

const texts = PrefetchTexts(
  title: 'Preload next song',
  always: 'Always',
  wifiOnly: 'Wi-Fi only',
  never: 'Never',
  neverHint: 'There will be a pause between songs',
);

Future<PrefetchPolicy> loaded(Map<String, Object> stored) async {
  SharedPreferences.setMockInitialValues(stored);
  final p = PrefetchPolicy();
  await p.load();
  return p;
}

Future<Object?> stored() async =>
    (await SharedPreferences.getInstance()).get('prefetch_mode');

Future<void> pumpSection(WidgetTester tester, PrefetchPolicy p) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PrefetchSection(policy: p, texts: texts),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mayPrefetch', () {
    final cases = <(PrefetchMode, bool, bool, bool)>[
      (PrefetchMode.always, true, false, true),
      (PrefetchMode.always, false, false, true),
      (PrefetchMode.always, false, true, true),
      (PrefetchMode.always, true, true, true),
      (PrefetchMode.wifiOnly, true, false, true),
      (PrefetchMode.wifiOnly, false, false, false),
      (PrefetchMode.wifiOnly, false, true, false),
      (PrefetchMode.wifiOnly, true, true, false),
      (PrefetchMode.never, true, false, false),
      (PrefetchMode.never, false, false, false),
      (PrefetchMode.never, false, true, false),
      (PrefetchMode.never, true, true, false),
    ];
    for (final (mode, wifi, metered, want) in cases) {
      test('${mode.name} wifi=$wifi metered=$metered → $want', () {
        expect(mayPrefetch(mode, onWifi: wifi, metered: metered), want);
      });
    }
  });

  test('exactly three modes, names are storage contract', () {
    expect(PrefetchMode.values.map((m) => m.name), [
      'always',
      'wifiOnly',
      'never',
    ]);
  });

  group('storage', () {
    test('before load: always', () {
      expect(PrefetchPolicy().mode, PrefetchMode.always);
    });

    test('empty: always', () async {
      expect((await loaded({})).mode, PrefetchMode.always);
    });

    for (final m in PrefetchMode.values) {
      test('saved ${m.name} is read', () async {
        expect((await loaded({'prefetch_mode': m.name})).mode, m);
      });
    }

    for (final bad in <Object>['WIFI', 'wifi_only', '', ' never', 'Never']) {
      test('unknown \'$bad\' - always', () async {
        expect(
          (await loaded({'prefetch_mode': bad})).mode,
          PrefetchMode.always,
        );
      });
    }

    test('not a string - always', () async {
      expect((await loaded({'prefetch_mode': 2})).mode, PrefetchMode.always);
      expect((await loaded({'prefetch_mode': true})).mode, PrefetchMode.always);
    });

    test('foreign keys do not interfere', () async {
      final p = await loaded({'other': 'never', 'prefetch_mode': 'wifiOnly'});
      expect(p.mode, PrefetchMode.wifiOnly);
    });

    test('load notifies only on change', () async {
      SharedPreferences.setMockInitialValues({});
      final p = PrefetchPolicy();
      var n = 0;
      p.addListener(() => n++);
      await p.load();
      expect(n, 0);
      SharedPreferences.setMockInitialValues({'prefetch_mode': 'never'});
      await p.load();
      expect(n, 1);
    });

    test('repeated load: value gone - always again', () async {
      final p = await loaded({'prefetch_mode': 'never'});
      SharedPreferences.setMockInitialValues({});
      await p.load();
      expect(p.mode, PrefetchMode.always);
    });

    test('set writes mode name', () async {
      final p = await loaded({});
      await p.set(PrefetchMode.wifiOnly);
      expect(await stored(), 'wifiOnly');
      expect(p.mode, PrefetchMode.wifiOnly);
      await p.set(PrefetchMode.never);
      expect(await stored(), 'never');
    });

    test('set survives restart', () async {
      final p = await loaded({});
      await p.set(PrefetchMode.never);
      final again = PrefetchPolicy();
      await again.load();
      expect(again.mode, PrefetchMode.never);
    });

    test('set same mode - no notification or write', () async {
      final p = await loaded({});
      var n = 0;
      p.addListener(() => n++);
      await p.set(PrefetchMode.always);
      expect(n, 0);
      expect(await stored(), isNull);
    });

    test('set different mode - one notification', () async {
      final p = await loaded({});
      var n = 0;
      p.addListener(() => n++);
      await p.set(PrefetchMode.never);
      expect(n, 1);
    });
  });

  group('settings section', () {
    testWidgets('title, 3 options, subtitle for \'never\'', (t) async {
      final p = await loaded({});
      await pumpSection(t, p);
      for (final s in [
        texts.title,
        texts.always,
        texts.wifiOnly,
        texts.never,
        texts.neverHint,
      ]) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
    });

    testWidgets('current mode is selected', (t) async {
      final sem = t.ensureSemantics();
      final p = await loaded({'prefetch_mode': 'wifiOnly'});
      await pumpSection(t, p);
      final tile = t.widget<RadioListTile<PrefetchMode>>(
        find.ancestor(
          of: find.text(texts.wifiOnly),
          matching: find.byType(RadioListTile<PrefetchMode>),
        ),
      );
      expect(tile.value, PrefetchMode.wifiOnly);
      expect(
        t.getSemantics(find.text(texts.wifiOnly)),
        isSemantics(isChecked: true),
      );
      expect(
        t.getSemantics(find.text(texts.always)),
        isSemantics(isChecked: false),
      );
      sem.dispose();
    });

    testWidgets('tap selects and saves', (t) async {
      final p = await loaded({});
      await pumpSection(t, p);
      await t.tap(find.text(texts.never));
      await t.pumpAndSettle();
      expect(p.mode, PrefetchMode.never);
      expect(await stored(), 'never');
      await t.tap(find.text(texts.wifiOnly));
      await t.pumpAndSettle();
      expect(p.mode, PrefetchMode.wifiOnly);
    });

    testWidgets('external change updates selection', (t) async {
      final sem = t.ensureSemantics();
      final p = await loaded({});
      await pumpSection(t, p);
      await p.set(PrefetchMode.never);
      await t.pump();
      expect(
        t.getSemantics(find.text(texts.never)),
        isSemantics(isChecked: true),
      );
      sem.dispose();
    });

    testWidgets('large font - subtitle not truncated', (t) async {
      final p = await loaded({});
      await t.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 780),
            textScaler: TextScaler.linear(2),
          ),
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PrefetchSection(policy: p, texts: texts),
              ),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      final hint = t.widget<Text>(find.text(texts.neverHint));
      expect(hint.maxLines, isNull);
      expect(hint.overflow, isNot(TextOverflow.ellipsis));
    });
  });
}
