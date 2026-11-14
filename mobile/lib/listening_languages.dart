import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scope of the languages: podcasts or books.
enum LanguageScope { podcasts, books }

/// Listening language with an ISO 639-1 code and its own name.
@immutable
class ListeningLanguage {
  final String code;
  final String native;

  const ListeningLanguage(this.code, this.native);

  /// UI label taking the translation [translated] into account.
  /// If the translation is empty or equals the own name, a single word.
  String labelWith(String translated) {
    if (translated.isEmpty || translated == native) {
      return native;
    }
    return '$native · $translated';
  }

  @override
  String toString() => '$code: $native';
}

/// Languages available for choice (ISO 639-1, no repeats, no flags).
/// First is ru, second is en, then the other major languages (up to 14 codes).
const List<ListeningLanguage> knownLanguages = [
  ListeningLanguage('ru', 'Русский'),
  ListeningLanguage('en', 'English'),
  ListeningLanguage('uk', 'Українська'),
  ListeningLanguage('de', 'Deutsch'),
  ListeningLanguage('fr', 'Français'),
  ListeningLanguage('es', 'Español'),
  ListeningLanguage('it', 'Italiano'),
  ListeningLanguage('pl', 'Polski'),
  ListeningLanguage('pt', 'Português'),
  ListeningLanguage('tr', 'Türkçe'),
  ListeningLanguage('be', 'Беларуская'),
  ListeningLanguage('zh', '中文'),
  ListeningLanguage('ja', '日本語'),
  ListeningLanguage('ko', '한국어'),
];

final Set<String> _knownCodes = {for (final l in knownLanguages) l.code};

/// Listening-language setting for podcasts and books (FT-689, Р-A105).
class ListeningLanguages extends ChangeNotifier {
  ListeningLanguages({String Function()? phoneLanguage})
    : _initialCode = _resolvePhoneLanguage(phoneLanguage) {
    _podcasts = _initialSelection();
    _books = _initialSelection();
  }

  static const _podcastsKey = 'listen-langs-podcasts';
  static const _booksKey = 'listen-langs-books';

  final String? _initialCode;
  Set<String>? _podcasts;
  Set<String>? _books;
  bool _disposed = false;

  Set<String>? _initialSelection() {
    final code = _initialCode;
    return code != null ? {code} : null;
  }

  Set<String>? _selected(LanguageScope scope) =>
      scope == LanguageScope.podcasts ? _podcasts : _books;

  void _setSelected(LanguageScope scope, Set<String>? value) {
    if (scope == LanguageScope.podcasts) {
      _podcasts = value;
    } else {
      _books = value;
    }
  }

  static String _keyFor(LanguageScope scope) =>
      scope == LanguageScope.podcasts ? _podcastsKey : _booksKey;

  static String? _resolvePhoneLanguage(String Function()? phoneLanguage) {
    try {
      final raw = phoneLanguage != null
          ? phoneLanguage()
          : PlatformDispatcher.instance.locale.languageCode;
      final cleaned = raw.trim().toLowerCase();
      if (_knownCodes.contains(cleaned)) {
        return cleaned;
      }
    } catch (_) {
      // An exception: treat it as "all".
    }
    return null;
  }

  Set<String>? _parseStored(Object? raw) {
    if (raw == null || raw is! List) {
      return _initialSelection();
    }
    final list = raw.whereType<String>().toList();
    if (list.contains('*')) {
      return null;
    }
    final valid = list.where(_knownCodes.contains).toSet();
    if (valid.isEmpty) {
      return _initialSelection();
    }
    return valid;
  }

  /// Selected languages in the order of [knownLanguages]. `null` means "all" is selected.
  List<String>? chosen(LanguageScope scope) {
    final selected = _selected(scope);
    if (selected == null) return null;
    return [
      for (final lang in knownLanguages)
        if (selected.contains(lang.code)) lang.code,
    ];
  }

  /// Whether "all" languages are selected for the given scope.
  bool isAll(LanguageScope scope) => _selected(scope) == null;

  /// Loads the saved settings from [SharedPreferences].
  Future<void> load() async {
    if (_disposed) return;
    var pods = _initialSelection();
    var bks = _initialSelection();
    try {
      final prefs = await SharedPreferences.getInstance();
      pods = _parseStored(prefs.get(_podcastsKey));
      bks = _parseStored(prefs.get(_booksKey));
    } catch (_) {
      // A storage failure does not escape as an exception.
    }
    if (_disposed) return;
    _podcasts = pods;
    _books = bks;
    notifyListeners();
  }

  /// Toggles a language:
  /// - with "all", only this language remains;
  /// - unchecking the last box switches to "all" mode;
  /// - an unknown code is ignored without calling listeners.
  Future<void> toggle(LanguageScope scope, String code) async {
    if (_disposed) return;
    if (!_knownCodes.contains(code)) return;

    final current = _selected(scope);
    if (current == null) {
      _setSelected(scope, {code});
    } else {
      final next = Set<String>.of(current);
      if (next.contains(code)) {
        next.remove(code);
        if (next.isEmpty) {
          _setSelected(scope, null);
        } else {
          _setSelected(scope, next);
        }
      } else {
        next.add(code);
        _setSelected(scope, next);
      }
    }

    notifyListeners();
    await _save(scope);
  }

  /// Resets the choice to "all" languages. If already "all", does nothing.
  Future<void> setAll(LanguageScope scope) async {
    if (_disposed || isAll(scope)) return;
    _setSelected(scope, null);
    notifyListeners();
    await _save(scope);
  }

  /// Checks whether the given language is allowed for the scope:
  /// - "all" lets through any language and a missing language;
  /// - a book without a language (`null`, empty, whitespace) counts as Russian;
  /// - a podcast without a language always passes;
  /// - case and whitespace in [language] do not affect the check.
  bool allows(LanguageScope scope, String? language) {
    if (isAll(scope)) return true;
    final cleaned = language?.trim().toLowerCase();
    if (cleaned == null || cleaned.isEmpty) {
      if (scope == LanguageScope.podcasts) {
        return true;
      }
      return _selected(scope)!.contains('ru');
    }
    return _selected(scope)!.contains(cleaned);
  }

  /// Query parameter: codes comma-separated with no spaces in the order of [knownLanguages],
  /// or `null` if "all" is selected.
  String? queryParam(LanguageScope scope) {
    final list = chosen(scope);
    if (list == null) return null;
    return list.join(',');
  }

  Future<void> _save(LanguageScope scope) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _keyFor(scope);
      final list = chosen(scope) ?? const ['*'];
      await prefs.setStringList(key, list);
    } catch (_) {
      // A storage failure does not escape as an exception.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
