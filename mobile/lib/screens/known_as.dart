import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';

/// Artist alias from catalog response (FT-746, Im-2).
class ArtistAlias {
  const ArtistAlias(this.name, [this.locale]);

  final String name;
  final String? locale;

  /// Parses alias list from server JSON response.
  ///
  /// Skips malformed items (not a list, not a map, empty name),
  /// trims whitespace from name edges, converts non-string `locale` to `null`.
  static List<ArtistAlias> listFrom(Object? json) {
    if (json is! List) return const [];
    final result = <ArtistAlias>[];
    for (final item in json) {
      if (item is! Map) continue;
      final rawName = item['name'];
      if (rawName is! String) continue;
      final name = rawName.trim();
      if (name.isEmpty) continue;
      final rawLocale = item['locale'];
      final locale = rawLocale is String && rawLocale.trim().isNotEmpty
          ? rawLocale.trim()
          : null;
      result.add(ArtistAlias(name, locale));
    }
    return result;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtistAlias &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          locale == other.locale;

  @override
  int get hashCode => Object.hash(name, locale);

  @override
  String toString() => 'ArtistAlias($name, locale: $locale)';
}

/// "Other spellings" section for artist (FT-746, Im-2).
///
/// Displays up to five alternative names: first matching UI language,
/// then Latin (letters up to U+024F), then remainder. Self name and
/// case-insensitive duplicates are filtered out. If nothing to display —
/// empty widget with height 0.
class KnownAs extends StatelessWidget {
  const KnownAs({
    super.key,
    required this.name,
    required this.aliases,
    this.language,
  });

  final String name;
  final List<ArtistAlias> aliases;
  final String? language;

  static final _letterPattern = RegExp(r'\p{L}', unicode: true);

  static bool _isLatin(String text) {
    var hasLetter = false;
    for (final rune in text.runes) {
      if (_letterPattern.hasMatch(String.fromCharCode(rune))) {
        // Latin with diacritics — up to U+024F and Vietnamese (U+1E00–U+1EFF).
        if (rune > 0x024F && (rune < 0x1E00 || rune > 0x1EFF)) return false;
        hasLetter = true;
      }
    }
    return hasLetter;
  }

  static bool _matchesLanguage(String? aliasLocale, String? targetLanguage) {
    if (aliasLocale == null || targetLanguage == null) return false;
    final a = aliasLocale.trim().toLowerCase().replaceAll('_', '-');
    final t = targetLanguage.trim().toLowerCase().replaceAll('_', '-');
    if (a.isEmpty || t.isEmpty) return false;
    return a == t || a.split('-').first == t.split('-').first;
  }

  static List<String> _resolveNames({
    required String artistName,
    required List<ArtistAlias> aliases,
    required String? language,
  }) {
    final langMatches = <ArtistAlias>[];
    final latinMatches = <ArtistAlias>[];
    final otherMatches = <ArtistAlias>[];

    for (final alias in aliases) {
      if (_matchesLanguage(alias.locale, language)) {
        langMatches.add(alias);
      } else if (_isLatin(alias.name)) {
        latinMatches.add(alias);
      } else {
        otherMatches.add(alias);
      }
    }

    final ordered = [...langMatches, ...latinMatches, ...otherMatches];
    final seen = <String>{artistName.trim().toLowerCase()};
    final result = <String>[];

    for (final alias in ordered) {
      final clean = alias.name.trim();
      if (clean.isEmpty) continue;
      final lower = clean.toLowerCase();
      if (seen.add(lower)) {
        result.add(clean);
        if (result.length == 5) break;
      }
    }

    return result;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveLang =
        language ?? Localizations.maybeLocaleOf(context)?.languageCode;
    final names = _resolveNames(
      artistName: name,
      aliases: aliases,
      language: effectiveLang,
    );

    if (names.isEmpty) {
      return const SizedBox.shrink();
    }

    final loc = l10n(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            loc.knownAsHeading,
            style: ApertonoText.sectionTitle.copyWith(
              color: ApertonoColors.textPrimary,
            ),
          ),
        ),
        Column(
          key: const Key('known-as-names'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in names)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 2,
                ),
                child: Semantics(
                  label: loc.knownAsSpoken(item),
                  excludeSemantics: true,
                  child: Text(
                    item,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ApertonoText.trackArtist,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
