import 'dart:async';

import 'package:flutter/material.dart';

import '../listening_languages.dart';
import '../theme.dart';

/// Title and "All languages" item texts for [LanguagesSheet].
class LanguagesTexts {
  const LanguagesTexts({required this.title, required this.all, this.name});

  final String title;
  final String all;
  final String Function(String code)? name;
}

/// Language selection sheet for podcasts and books (FT-706, P-A105).
class LanguagesSheet extends StatelessWidget {
  const LanguagesSheet({
    super.key,
    required this.languages,
    required this.scope,
    required this.texts,
  });

  final ListeningLanguages languages;
  final LanguageScope scope;
  final LanguagesTexts texts;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: languages,
      builder: (context, _) {
        final isAll = languages.isAll(scope);
        final chosen = languages.chosen(scope)?.toSet() ?? const <String>{};

        return Material(
          color: ApertonoColors.surface,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(texts.title, style: ApertonoText.sectionTitle),
              ),
              CheckboxListTile(
                key: const ValueKey('lang-all'),
                value: isAll,
                controlAffinity: ListTileControlAffinity.trailing,
                activeColor: ApertonoColors.accent,
                title: Text(texts.all),
                onChanged: (_) => unawaited(languages.setAll(scope)),
              ),
              for (final lang in knownLanguages)
                CheckboxListTile(
                  key: ValueKey('lang-${lang.code}'),
                  value: !isAll && chosen.contains(lang.code),
                  controlAffinity: ListTileControlAffinity.trailing,
                  activeColor: ApertonoColors.accent,
                  title: Text(
                    lang.labelWith(texts.name?.call(lang.code) ?? ''),
                  ),
                  onChanged: (_) =>
                      unawaited(languages.toggle(scope, lang.code)),
                ),
            ],
          ),
        );
      },
    );
  }
}
