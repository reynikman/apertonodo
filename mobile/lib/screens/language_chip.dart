import 'package:flutter/material.dart';

import '../listening_languages.dart';
import '../theme.dart';

final Map<String, String> _knownNative = {
  for (final lang in knownLanguages) lang.code: lang.native,
};

/// String set for language chip, empty search results, and language tag (FT-734, Yaz-5).
class LanguageChipTexts {
  const LanguageChipTexts({
    required this.chosen,
    required this.all,
    required this.nothing,
    required this.searchAll,
    required this.unknown,
  });

  final String Function(String names) chosen;
  final String all;
  final String nothing;
  final String searchAll;
  final String unknown;
}

String _chipLabel(
  ListeningLanguages languages,
  LanguageScope scope,
  LanguageChipTexts texts,
) {
  if (languages.isAll(scope)) {
    return texts.all;
  }
  final selected = languages.chosen(scope);
  if (selected == null || selected.isEmpty) {
    return texts.all;
  }
  final names = [
    for (final code in selected)
      if (_knownNative.containsKey(code)) _knownNative[code]!,
  ].join(', ');
  return texts.chosen(names);
}

/// Language filter chip above search results (FT-734, Yaz-5).
class LanguageChip extends StatelessWidget {
  const LanguageChip({
    super.key,
    required this.languages,
    required this.scope,
    required this.texts,
    required this.onTap,
  });

  final ListeningLanguages languages;
  final LanguageScope scope;
  final LanguageChipTexts texts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: languages,
      builder: (context, _) {
        final label = _chipLabel(languages, scope, texts);
        return Semantics(
          key: const ValueKey('language-chip'),
          button: true,
          label: label,
          excludeSemantics: true,
          onTap: onTap,
          child: Material(
            color: ApertonoColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.all(
                Radius.circular(ApertonoRadii.medium),
              ),
              side: const BorderSide(color: ApertonoColors.border),
            ),
            child: InkWell(
              borderRadius: const BorderRadius.all(
                Radius.circular(ApertonoRadii.medium),
              ),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Align(
                    alignment: Alignment.center,
                    widthFactor: 1.0,
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontFamily: ApertonoFonts.sans,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: ApertonoColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Empty search results prompt offering to search in all languages (FT-734, Yaz-5).
class LanguageEmpty extends StatelessWidget {
  const LanguageEmpty({
    super.key,
    required this.texts,
    required this.onSearchAll,
  });

  final LanguageChipTexts texts;
  final VoidCallback onSearchAll;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              texts.nothing,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontSize: 14,
                color: ApertonoColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('language-search-all'),
              onPressed: onSearchAll,
              style: FilledButton.styleFrom(
                backgroundColor: ApertonoColors.accent,
                foregroundColor: ApertonoColors.background,
              ),
              child: Text(texts.searchAll),
            ),
          ],
        ),
      ),
    );
  }
}

/// Language tag in result row (FT-734, Yaz-5).
///
/// Returns `null` if tag is not needed (results are not mixed and language
/// is among selected, or "all" selected and results are not mixed).
/// If tag is needed:
/// - known code — native language name (`native`);
/// - unknown code — uppercase code;
/// - `null` — `texts.unknown`.
String? languageTag(
  String? language, {
  required List<String>? chosen,
  required bool mixed,
  required LanguageChipTexts texts,
}) {
  final cleanLang = language?.trim().toLowerCase();
  final inChosen =
      cleanLang != null &&
      chosen != null &&
      chosen.map((c) => c.trim().toLowerCase()).contains(cleanLang);

  final shouldShow = chosen == null ? mixed : (mixed || !inChosen);
  if (!shouldShow) {
    return null;
  }

  if (cleanLang == null || cleanLang.isEmpty) {
    return texts.unknown;
  }

  final native = _knownNative[cleanLang];
  if (native != null) {
    return native;
  }

  return cleanLang.toUpperCase();
}
