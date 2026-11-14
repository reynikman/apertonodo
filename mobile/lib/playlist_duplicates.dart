import 'package:flutter/material.dart';

class DuplicateSplit {
  final List<String> ordered;
  final Set<String> duplicates;
  final List<String> fresh;

  const DuplicateSplit({
    required this.ordered,
    required this.duplicates,
    required this.fresh,
  });

  bool get hasDuplicates => duplicates.isNotEmpty;
}

DuplicateSplit duplicatesOf(
  Iterable<String> existing,
  Iterable<String> adding,
) {
  final existingSet = existing is Set<String> ? existing : existing.toSet();
  final ordered = <String>[];
  final duplicates = <String>{};
  final fresh = <String>[];
  final seenInAdding = <String>{};

  for (final id in adding) {
    if (seenInAdding.add(id)) {
      ordered.add(id);
      if (existingSet.contains(id)) {
        duplicates.add(id);
      } else {
        fresh.add(id);
      }
    }
  }

  return DuplicateSplit(ordered: ordered, duplicates: duplicates, fresh: fresh);
}

enum DuplicateChoice { addAll, onlyNew, cancel }

List<String>? resolveDuplicates(DuplicateSplit split, DuplicateChoice? choice) {
  switch (choice) {
    case DuplicateChoice.addAll:
      return split.ordered;
    case DuplicateChoice.onlyNew:
      return split.fresh.isEmpty ? null : split.fresh;
    case DuplicateChoice.cancel:
    case null:
      return null;
  }
}

class DuplicateTexts {
  final String Function(int count) title;
  final String addAll;
  final String onlyNew;
  final String cancel;

  const DuplicateTexts({
    required this.title,
    required this.addAll,
    required this.onlyNew,
    required this.cancel,
  });
}

Future<DuplicateChoice?> askDuplicates(
  BuildContext context,
  DuplicateSplit split,
  DuplicateTexts texts,
) async {
  if (!split.hasDuplicates) {
    return DuplicateChoice.addAll;
  }
  return showModalBottomSheet<DuplicateChoice>(
    context: context,
    useRootNavigator: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  texts.title(split.duplicates.length),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListTile(
                title: Text(texts.addAll),
                onTap: () => Navigator.of(context).pop(DuplicateChoice.addAll),
              ),
              if (split.fresh.isNotEmpty)
                ListTile(
                  title: Text(texts.onlyNew),
                  onTap: () =>
                      Navigator.of(context).pop(DuplicateChoice.onlyNew),
                ),
              ListTile(
                title: Text(texts.cancel),
                onTap: () => Navigator.of(context).pop(DuplicateChoice.cancel),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
