// FT-689: listening languages (P-A105 items 4–5). Lead check written before work.
//
// Contract:
// - two independent settings (podcasts, books): multiple languages or "all" (`null`);
// - initial value is device language if present in `knownLanguages`, otherwise "all";
// - storage: `listen-langs-podcasts` / `listen-langs-books`, list of codes or `['*']`;
// - unknown code in storage is discarded; if no codes left, fallback to initial value;
// - unchecking the last checkbox means "all"; checking when "all" selects only this language;
// - book without language is Russian; podcast without language passes;
// - `queryParam` is comma-separated codes in list order, "all" is `null`.
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/listening_languages.dart';
import 'package:shared_preferences/shared_preferences.dart';

const pods = LanguageScope.podcasts;
const books = LanguageScope.books;

Future<ListeningLanguages> loaded(
  Map<String, Object> stored, {
  String phone = 'ru',
}) async {
  SharedPreferences.setMockInitialValues(stored);
  final langs = ListeningLanguages(phoneLanguage: () => phone);
  await langs.load();
  return langs;
}

Future<List<String>?> storedList(String key) async =>
    (await SharedPreferences.getInstance()).getStringList(key);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('initial value', () {
    test('Russian phone — Russian for both', () async {
      final l = await loaded({});
      expect(l.chosen(pods), ['ru']);
      expect(l.chosen(books), ['ru']);
      expect(l.isAll(pods), isFalse);
    });

    test('German phone — German', () async {
      final l = await loaded({}, phone: 'de');
      expect(l.chosen(pods), ['de']);
      expect(l.chosen(books), ['de']);
    });

    test('phone code with different case and space', () async {
      final l = await loaded({}, phone: ' EN ');
      expect(l.chosen(pods), ['en']);
    });

    test('unknown phone language — «all»', () async {
      final l = await loaded({}, phone: 'sw');
      expect(l.chosen(pods), isNull);
      expect(l.isAll(books), isTrue);
    });

    test('phone language throws exception — «all»', () async {
      SharedPreferences.setMockInitialValues({});
      final l = ListeningLanguages(phoneLanguage: () => throw StateError('x'));
      await l.load();
      expect(l.isAll(pods), isTrue);
      expect(l.isAll(books), isTrue);
    });

    test('before load — already phone language', () {
      final l = ListeningLanguages(phoneLanguage: () => 'fr');
      expect(l.chosen(pods), ['fr']);
      expect(l.chosen(books), ['fr']);
    });

    test('without phoneLanguage takes system locale, no crash', () {
      final l = ListeningLanguages();
      final c = l.chosen(pods);
      expect(c == null || c.length == 1, isTrue);
    });
  });

  group('storage', () {
    test('saved codes are read in list order', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['de', 'ru', 'en'],
        'listen-langs-books': ['en'],
      });
      expect(l.chosen(pods), ['ru', 'en', 'de']);
      expect(l.chosen(books), ['en']);
    });

    test('asterisk means «all»', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['*'],
      });
      expect(l.isAll(pods), isTrue);
      expect(l.chosen(books), ['ru']);
    });

    test('asterisk with codes still means «all»', () async {
      final l = await loaded({
        'listen-langs-books': ['ru', '*'],
      });
      expect(l.isAll(books), isTrue);
    });

    test('unknown codes are discarded', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['xx', 'en', 'RU', ''],
      });
      expect(l.chosen(pods), ['en']);
    });

    test('only unknown remaining — initial value', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['xx', 'yy'],
      }, phone: 'de');
      expect(l.chosen(pods), ['de']);
    });

    test('empty list — initial value', () async {
      final l = await loaded({'listen-langs-books': <String>[]}, phone: 'en');
      expect(l.chosen(books), ['en']);
    });

    test('non-list value — initial value, no exception', () async {
      final l = await loaded({'listen-langs-podcasts': 'ru,en'}, phone: 'de');
      expect(l.chosen(pods), ['de']);
      expect(l.chosen(books), ['de']);
    });

    test('load notifies listeners', () async {
      SharedPreferences.setMockInitialValues({});
      final l = ListeningLanguages(phoneLanguage: () => 'ru');
      var calls = 0;
      l.addListener(() => calls++);
      await l.load();
      expect(calls, 1);
    });

    test('load after dispose does not notify or throw', () async {
      SharedPreferences.setMockInitialValues({
        'listen-langs-podcasts': ['en'],
      });
      final l = ListeningLanguages(phoneLanguage: () => 'ru');
      final f = l.load();
      l.dispose();
      await f;
    });
  });

  group('checkboxes', () {
    test('add language', () async {
      final l = await loaded({});
      await l.toggle(pods, 'en');
      expect(l.chosen(pods), ['ru', 'en']);
      expect(await storedList('listen-langs-podcasts'), ['ru', 'en']);
    });

    test('remove language', () async {
      final l = await loaded({
        'listen-langs-books': ['ru', 'en'],
      });
      await l.toggle(books, 'ru');
      expect(l.chosen(books), ['en']);
      expect(await storedList('listen-langs-books'), ['en']);
    });

    test('remove last — «all», asterisk in storage', () async {
      final l = await loaded({});
      await l.toggle(pods, 'ru');
      expect(l.isAll(pods), isTrue);
      expect(await storedList('listen-langs-podcasts'), ['*']);
    });

    test('check on «all» keeps only this language', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['*'],
      });
      await l.toggle(pods, 'de');
      expect(l.chosen(pods), ['de']);
      expect(await storedList('listen-langs-podcasts'), ['de']);
    });

    test('unknown code — no-op, listeners silent', () async {
      final l = await loaded({});
      var calls = 0;
      l.addListener(() => calls++);
      await l.toggle(pods, 'xx');
      await l.toggle(pods, 'RU');
      expect(l.chosen(pods), ['ru']);
      expect(calls, 0);
      expect(await storedList('listen-langs-podcasts'), isNull);
    });

    test('podcasts and books are independent', () async {
      final l = await loaded({});
      await l.toggle(pods, 'en');
      expect(l.chosen(books), ['ru']);
      await l.setAll(books);
      expect(l.chosen(pods), ['ru', 'en']);
      expect(await storedList('listen-langs-podcasts'), ['ru', 'en']);
      expect(await storedList('listen-langs-books'), ['*']);
    });

    test('checkbox notifies listeners once', () async {
      final l = await loaded({});
      var calls = 0;
      l.addListener(() => calls++);
      await l.toggle(books, 'en');
      expect(calls, 1);
    });

    test('after dispose checkbox does nothing', () async {
      final l = await loaded({});
      l.dispose();
      await l.toggle(pods, 'en');
      expect(await storedList('listen-langs-podcasts'), isNull);
    });
  });

  group('"all"', () {
    test('setAll saves asterisk and notifies', () async {
      final l = await loaded({});
      var calls = 0;
      l.addListener(() => calls++);
      await l.setAll(pods);
      expect(l.isAll(pods), isTrue);
      expect(l.chosen(pods), isNull);
      expect(calls, 1);
      expect(await storedList('listen-langs-podcasts'), ['*']);
    });

    test('setAll on «all» — no-op', () async {
      final l = await loaded({
        'listen-langs-books': ['*'],
      });
      var calls = 0;
      l.addListener(() => calls++);
      await l.setAll(books);
      expect(calls, 0);
    });

    test('after dispose setAll does nothing', () async {
      final l = await loaded({});
      l.dispose();
      await l.setAll(books);
      expect(await storedList('listen-langs-books'), isNull);
    });
  });

  group('allows', () {
    test('«all» allows everything, including empty', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['*'],
        'listen-langs-books': ['*'],
      });
      for (final s in [pods, books]) {
        expect(l.allows(s, 'xx'), isTrue);
        expect(l.allows(s, null), isTrue);
        expect(l.allows(s, ''), isTrue);
      }
    });

    test('selected language — yes, other — no', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['ru', 'en'],
      });
      expect(l.allows(pods, 'en'), isTrue);
      expect(l.allows(pods, 'de'), isFalse);
    });

    test('case and whitespace in record language ignored', () async {
      final l = await loaded({});
      expect(l.allows(pods, ' RU '), isTrue);
      expect(l.allows(books, 'Ru'), isTrue);
    });

    test('book without language is Russian', () async {
      final ru = await loaded({});
      expect(ru.allows(books, null), isTrue);
      expect(ru.allows(books, ''), isTrue);
      expect(ru.allows(books, '  '), isTrue);
      final en = await loaded({
        'listen-langs-books': ['en'],
      });
      expect(en.allows(books, null), isFalse);
      expect(en.allows(books, ''), isFalse);
    });

    test('podcast without language passes for any selection', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['de'],
      });
      expect(l.allows(pods, null), isTrue);
      expect(l.allows(pods, ''), isTrue);
    });
  });

  group('queryParam', () {
    test('comma-separated codes in list order', () async {
      final l = await loaded({
        'listen-langs-podcasts': ['de', 'ru'],
      });
      expect(l.queryParam(pods), 'ru,de');
    });

    test('«all» — null', () async {
      final l = await loaded({
        'listen-langs-books': ['*'],
      });
      expect(l.queryParam(books), isNull);
    });

    test('single language — no comma', () async {
      final l = await loaded({});
      expect(l.queryParam(books), 'ru');
    });
  });

  group('language list', () {
    test('Russian first, English second', () {
      expect(knownLanguages[0].code, 'ru');
      expect(knownLanguages[1].code, 'en');
    });

    test('codes are unique, two lowercase ASCII letters', () {
      final codes = knownLanguages.map((l) => l.code).toList();
      expect(codes.toSet().length, codes.length);
      for (final c in codes) {
        expect(RegExp(r'^[a-z]{2}$').hasMatch(c), isTrue, reason: c);
      }
    });

    test(
      'label: "Deutsch · German name", matches endonym title — only one word',
      () {
        // FT-808: title translation comes from outside (app strings).
        final de = knownLanguages.firstWhere((l) => l.code == 'de');
        expect(de.labelWith('Немецкий'), 'Deutsch · Немецкий');
        expect(de.labelWith('German'), 'Deutsch · German');
        expect(knownLanguages.first.labelWith('Русский'), 'Русский');
        final en = knownLanguages.firstWhere((l) => l.code == 'en');
        expect(en.labelWith('English'), 'English');
        expect(en.labelWith(''), 'English');
      },
    );

    test('no flag emojis in labels', () {
      for (final l in knownLanguages) {
        expect(
          l.native.runes.any((r) => r >= 0x1F1E6 && r <= 0x1F1FF),
          isFalse,
          reason: l.code,
        );
      }
    });

    test('major languages present', () {
      final codes = knownLanguages.map((l) => l.code).toSet();
      expect(codes.containsAll({'ru', 'en', 'uk', 'de', 'fr', 'es'}), isTrue);
    });
  });
}
