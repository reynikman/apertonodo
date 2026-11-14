import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// Response to prompt after crash (FT-698).
enum CrashChoice { send, skip, never }

/// Sheet: "the app crashed last time — send a crash report?".
/// Swiping the sheet away is equivalent to "Not now".
Future<CrashChoice> askCrashReport(BuildContext context) async {
  final text = AppLocalizations.of(context);
  final choice = await showModalBottomSheet<CrashChoice>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            key: const Key('crash-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  text.crashTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(text.crashBody),
              ),
              ListTile(
                title: Text(text.crashSend),
                onTap: () => Navigator.of(context).pop(CrashChoice.send),
              ),
              ListTile(
                title: Text(text.crashSkip),
                onTap: () => Navigator.of(context).pop(CrashChoice.skip),
              ),
              ListTile(
                title: Text(text.crashNever),
                onTap: () => Navigator.of(context).pop(CrashChoice.never),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return choice ?? CrashChoice.skip;
}
