import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// Screen strings in the person's language (FT-600, Р-A91).
///
/// In the app they come from the `MaterialApp` delegate. A screen built without
/// delegates (as many tests build it) takes the phone language, like
/// the former `_ru()` fork: a Russian phone gets Russian, otherwise English.
AppLocalizations l10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    lookupAppLocalizations(
      Locale(
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ru'
            ? 'ru'
            : 'en',
      ),
    );
