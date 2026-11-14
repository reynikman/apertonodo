// FT-693: duplicate warning when adding to playlist (B-6). Lead check written before work.
//
// Contract:
// - comparison by immutable track ID (string), not by title;
// - `duplicatesOf(existing, adding)`: `ordered` — items to add without duplicates in original order;
//   `duplicates` — those already present; `fresh` — remaining ones in same order;
// - `resolveDuplicates`: addAll — `ordered`; onlyNew — `fresh` (empty — `null`); cancel and `null` — `null`;
// - `askDuplicates`: without duplicates sheet is not shown, immediate `addAll`; with duplicates — title `title(N)`,
//   "add all", "only new" (omitted if no new), "cancel"; tapping outside returns `null`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/playlist_duplicates.dart';

final texts = DuplicateTexts(
  title: (n) => '$n already in playlist',
  addAll: 'Add all',
  onlyNew: 'Only new',
  cancel: 'Cancel',
);

/// Button opens bottom sheet; result is stored in [out].
Future<void> pumpAsk(
  WidgetTester t,
  DuplicateSplit split,
  List<DuplicateChoice?> out,
) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async =>
                  out.add(await askDuplicates(context, split, texts)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  group('duplicatesOf', () {
    test('no overlaps', () {
      final s = duplicatesOf(['a', 'b'], ['c', 'd']);
      expect(s.ordered, ['c', 'd']);
      expect(s.duplicates, isEmpty);
      expect(s.fresh, ['c', 'd']);
      expect(s.hasDuplicates, isFalse);
    });

    test('some already exist', () {
      final s = duplicatesOf(['a', 'b', 'c'], ['x', 'b', 'y', 'a']);
      expect(s.ordered, ['x', 'b', 'y', 'a']);
      expect(s.duplicates, {'b', 'a'});
      expect(s.fresh, ['x', 'y']);
      expect(s.hasDuplicates, isTrue);
    });

    test('all already exist', () {
      final s = duplicatesOf(['a', 'b'], ['b', 'a']);
      expect(s.duplicates, {'a', 'b'});
      expect(s.fresh, isEmpty);
    });

    test('empty playlist', () {
      final s = duplicatesOf(const [], ['a', 'b']);
      expect(s.hasDuplicates, isFalse);
      expect(s.fresh, ['a', 'b']);
    });

    test('nothing to add', () {
      final s = duplicatesOf(['a'], const []);
      expect(s.ordered, isEmpty);
      expect(s.hasDuplicates, isFalse);
    });

    test('duplicate in added items — single entry, first order', () {
      final s = duplicatesOf(['z'], ['a', 'b', 'a', 'z', 'z', 'c']);
      expect(s.ordered, ['a', 'b', 'z', 'c']);
      expect(s.duplicates, {'z'});
      expect(s.fresh, ['a', 'b', 'c']);
    });

    test('duplicate in added items without playlist — not duplicate', () {
      final s = duplicatesOf(const [], ['a', 'a']);
      expect(s.ordered, ['a']);
      expect(s.hasDuplicates, isFalse);
    });

    test('exact comparison: case and spaces — different tracks', () {
      final s = duplicatesOf(['Ab'], ['ab', 'Ab ', 'Ab']);
      expect(s.duplicates, {'Ab'});
      expect(s.fresh, ['ab', 'Ab ']);
    });

    test('duplicate inside playlist does not interfere', () {
      final s = duplicatesOf(['a', 'a', 'a'], ['a', 'b']);
      expect(s.duplicates, {'a'});
      expect(s.fresh, ['b']);
    });

    test('large lists', () {
      final existing = [for (var i = 0; i < 5000; i++) 't$i'];
      final adding = [for (var i = 4000; i < 7000; i++) 't$i'];
      final s = duplicatesOf(existing, adding);
      expect(s.duplicates.length, 1000);
      expect(s.fresh.length, 2000);
      expect(s.fresh.first, 't5000');
    });
  });

  group('resolveDuplicates', () {
    final s = duplicatesOf(['a'], ['a', 'b', 'c']);
    final all = duplicatesOf(['a', 'b'], ['a', 'b']);

    test('add all', () {
      expect(resolveDuplicates(s, DuplicateChoice.addAll), ['a', 'b', 'c']);
    });
    test('only new', () {
      expect(resolveDuplicates(s, DuplicateChoice.onlyNew), ['b', 'c']);
    });
    test('only new, but no new — nothing', () {
      expect(resolveDuplicates(all, DuplicateChoice.onlyNew), isNull);
    });
    test('cancel — nothing', () {
      expect(resolveDuplicates(s, DuplicateChoice.cancel), isNull);
    });
    test('sheet dismissed outside — nothing', () {
      expect(resolveDuplicates(s, null), isNull);
    });
    test('add all when all are duplicates — all', () {
      expect(resolveDuplicates(all, DuplicateChoice.addAll), ['a', 'b']);
    });
  });

  group('leaf', () {
    testWidgets('no duplicates — no sheet, «add all» right away', (t) async {
      final out = <DuplicateChoice?>[];
      await pumpAsk(t, duplicatesOf(['a'], ['b']), out);
      expect(find.byType(BottomSheet), findsNothing);
      expect(out, [DuplicateChoice.addAll]);
    });

    testWidgets('header with duplicate count and three rows', (t) async {
      final out = <DuplicateChoice?>[];
      await pumpAsk(t, duplicatesOf(['a', 'b'], ['a', 'b', 'c']), out);
      expect(find.text('2 already in playlist'), findsOneWidget);
      expect(find.text('Add all'), findsOneWidget);
      expect(find.text('Only new'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(out, isEmpty);
    });

    testWidgets('all duplicates — no «only new» row', (t) async {
      final out = <DuplicateChoice?>[];
      await pumpAsk(t, duplicatesOf(['a', 'b'], ['b', 'a']), out);
      expect(find.text('2 already in playlist'), findsOneWidget);
      expect(find.text('Only new'), findsNothing);
      expect(find.text('Add all'), findsOneWidget);
    });

    for (final (label, want) in [
      ('Add all', DuplicateChoice.addAll),
      ('Only new', DuplicateChoice.onlyNew),
      ('Cancel', DuplicateChoice.cancel),
    ]) {
      testWidgets('tap «$label»', (t) async {
        final out = <DuplicateChoice?>[];
        await pumpAsk(t, duplicatesOf(['a'], ['a', 'b']), out);
        await t.tap(find.text(label));
        await t.pumpAndSettle();
        expect(out, [want]);
        expect(find.byType(BottomSheet), findsNothing);
      });
    }

    testWidgets('dismissing outside sheet — null', (t) async {
      final out = <DuplicateChoice?>[];
      await pumpAsk(t, duplicatesOf(['a'], ['a', 'b']), out);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      expect(out, [null]);
    });

    testWidgets('rows — tap targets at least 48', (t) async {
      final out = <DuplicateChoice?>[];
      await pumpAsk(t, duplicatesOf(['a'], ['a', 'b']), out);
      for (final label in ['Add all', 'Only new', 'Cancel']) {
        final box = t.getSize(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(box.height, greaterThanOrEqualTo(48), reason: label);
      }
    });

    testWidgets('large font — no overflow', (t) async {
      final out = <DuplicateChoice?>[];
      t.view.physicalSize = const Size(360, 780);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 780),
            textScaler: TextScaler.linear(2),
          ),
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async => out.add(
                      await askDuplicates(
                        context,
                        duplicatesOf(['a'], ['a', 'b']),
                        texts,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('1 already in playlist'), findsOneWidget);
    });
  });
}
