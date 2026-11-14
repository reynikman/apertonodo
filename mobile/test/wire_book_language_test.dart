// FT-785 (P-A105 items 4–5): book results filtered by listening languages
// for books; if all filtered out by language — model signals this and can
// display all languages for this query.
//
// What test does not prove: book page appearance and real server.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_client.dart';
import 'package:music_stream/book_search.dart';
import 'package:music_stream/listening_languages.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> hit(String ref, Object? language) => {
  'ref': ref,
  'title': 'T $ref',
  'author': 'A',
  'narrator': 'N',
  'year': 2019,
  'size_bytes': 100,
  'language': language,
};

void main() {
  late List<Map<String, Object?>> answer;
  late ListeningLanguages languages;
  late BookSearchModel model;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    answer = [];
    languages = ListeningLanguages(phoneLanguage: () => 'ru');
    model = BookSearchModel(
      BookClient(
        (method, path, {query, body}) async =>
            BookReply(200, {'books': answer}),
      ),
      pause: const Duration(milliseconds: 1),
      languages: languages,
    );
  });

  tearDown(() {
    model.dispose();
    languages.dispose();
  });

  List<String> refs() => [for (final b in model.results) b.ref];

  test('client reads language; defaults to Russian if unset', () {
    expect(FoundBook.fromJson(hit('r1', 'en'))!.language, 'en');
    expect(FoundBook.fromJson(hit('r2', null))!.language, 'ru');
  });

  test('only books in selected languages are shown', () async {
    answer = [hit('ru1', 'ru'), hit('en1', 'en'), hit('ru2', null)];
    model.setQuery('мастер');
    await model.submit();
    expect(refs(), ['ru1', 'ru2']);
    expect(model.hiddenByLanguage, 1);
  });

  test('all languages selected: no filter applied', () async {
    await languages.setAll(LanguageScope.books);
    answer = [hit('ru1', 'ru'), hit('en1', 'en')];
    model.setQuery('dune');
    await model.submit();
    expect(refs(), ['ru1', 'en1']);
    expect(model.hiddenByLanguage, 0);
  });

  test('all hidden by language: show all for this query', () async {
    answer = [hit('en1', 'en'), hit('de1', 'de')];
    model.setQuery('dune');
    await model.submit();
    expect(refs(), isEmpty);
    expect(model.hiddenByLanguage, 2);
    model.showAllLanguages();
    expect(refs(), ['en1', 'de1']);
    // Setting unchanged: subsequent request filters by selected languages again.
    expect(languages.isAll(LanguageScope.books), isFalse);
    model.setQuery('dune 2');
    await model.submit();
    expect(refs(), isEmpty);
  });
}
