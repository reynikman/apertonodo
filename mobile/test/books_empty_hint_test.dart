import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/l10n/app_localizations_en.dart';
import 'package:music_stream/l10n/app_localizations_ru.dart';

/// Owner finding 13.10 no. 10 (FT-852): an empty shelf said only "empty" and
/// left a newcomer guessing where books come from.
void main() {
  test('empty shelf says where to find a book', () {
    expect(AppLocalizationsRu().booksEmptyShelf, contains('поиск'));
    expect(AppLocalizationsRu().booksEmptyShelf, contains('На полку'));
    expect(AppLocalizationsEn().booksEmptyShelf, contains('search'));
  });
}
