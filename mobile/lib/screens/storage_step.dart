import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';
import 'space_hint.dart';

/// Step "Storage for music" after first login (FT-529, P-A60, rule 7).
///
/// User chooses once how much phone storage to dedicate to cache:
/// 10 GB, less, or none. Ceiling is "free minus 1 GB", but at most 50.
/// Free space is known only by Android; if Android did not report, ceiling
/// is 10 to avoid promising non-existent space. Screen occupies whole app,
/// like [LoginWizard].
class StorageStep extends StatefulWidget {
  const StorageStep({super.key, required this.freeBytes, required this.onDone});

  final int? freeBytes;
  final Future<void> Function(int bytes) onDone;

  @override
  State<StorageStep> createState() => _StorageStepState();
}

class _StorageStepState extends State<StorageStep> {
  static const _gib = 1024 * 1024 * 1024;

  late final int _ceiling = _cap(widget.freeBytes);
  late int _gigabytes = math.min(10, _ceiling);

  /// Whole gigabytes that can be dedicated: free minus gigabyte for system.
  static int _cap(int? free) {
    if (free == null) return 10;
    final room = (free - _gib) ~/ _gib;
    if (room < 0) return 0;
    return math.min(50, room);
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final theme = apertonoTheme();
    return MaterialApp(
      title: 'Apertono',
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      home: Scaffold(
        key: const Key('storage-step'),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      text.storageTitle,
                      key: const Key('storage-title'),
                      style: ApertonoText.screenTitle,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      text.storageDescription,
                      style: const TextStyle(
                        color: ApertonoColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_ceiling == 0)
                      Text(
                        text.storageNoRoom,
                        key: const Key('storage-no-room'),
                        style: const TextStyle(
                          color: ApertonoColors.textSecondary,
                        ),
                      )
                    else ...[
                      Text(
                        text.storageValue(_gigabytes),
                        key: const Key('storage-value'),
                        textAlign: TextAlign.center,
                        style: ApertonoText.sectionTitle,
                      ),
                      Slider(
                        key: const Key('storage-slider'),
                        min: 0,
                        max: _ceiling.toDouble(),
                        divisions: _ceiling,
                        value: _gigabytes.toDouble(),
                        onChanged: (value) =>
                            setState(() => _gigabytes = value.round()),
                      ),
                      DefaultTextStyle.merge(
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: ApertonoColors.textSecondary,
                        ),
                        child: SpaceHint(
                          key: const Key('storage-hint'),
                          bytes: _gigabytes * _gib,
                          texts: SpaceHintTexts(
                            fits: text.storageHintFits,
                            nothing: text.storageHintNothing,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      key: const Key('storage-done'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            ApertonoRadii.medium,
                          ),
                        ),
                      ),
                      onPressed: () => widget.onDone(_gigabytes * _gib),
                      child: Text(text.storageNext),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
