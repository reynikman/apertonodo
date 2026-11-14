import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../loudness.dart';
import '../quality_prefs.dart';
import '../theme.dart';

/// Audio quality selection sheet (FT-633, P-A94).
///
/// Three rows with title and description; selected one is checked — and only
/// it. Row is at least 48 dp, tapping calls `prefs.setMode`. Labels come
/// from `l10n`, so the sheet itself is bilingual.
class QualitySheet extends StatelessWidget {
  const QualitySheet({super.key, required this.prefs, this.loudness});

  final QualityPrefs prefs;
  final LoudnessGate? loudness;

  @override
  Widget build(BuildContext context) {
    final t = l10n(context);
    return SafeArea(
      child: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(t.qualityTitle, style: ApertonoText.sectionTitle),
            ),
            _QualityRow(
              id: 'auto',
              name: t.qualityAuto,
              hint: t.qualityAutoHint,
              selected: prefs.mode == QualityMode.auto,
              onTap: () => unawaited(prefs.setMode(QualityMode.auto)),
            ),
            _QualityRow(
              id: 'economy',
              name: t.qualityEconomy,
              hint: t.qualityEconomyHint,
              selected: prefs.mode == QualityMode.economy,
              onTap: () => unawaited(prefs.setMode(QualityMode.economy)),
            ),
            _QualityRow(
              id: 'lossless',
              name: t.qualityLossless,
              hint: t.qualityLosslessHint,
              selected: prefs.mode == QualityMode.lossless,
              onTap: () => unawaited(prefs.setMode(QualityMode.lossless)),
            ),
            if (loudness case final gate?)
              ListenableBuilder(
                listenable: gate,
                builder: (context, _) => SwitchListTile(
                  key: const Key('quality-loudness'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: Text(t.loudnessTitle, style: ApertonoText.trackTitle),
                  subtitle: Text(
                    t.loudnessHint,
                    style: ApertonoText.trackArtist,
                  ),
                  value: gate.enabled,
                  onChanged: (value) => unawaited(gate.setEnabled(value)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Mode row: title, description, and checkmark for selected item.
class _QualityRow extends StatelessWidget {
  const _QualityRow({
    required this.id,
    required this.name,
    required this.hint,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final String name;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('quality-$id'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      minTileHeight: 52,
      title: Text(
        name,
        style: selected
            ? ApertonoText.trackTitle.copyWith(color: ApertonoColors.accent)
            : ApertonoText.trackTitle,
      ),
      subtitle: Text(hint, style: ApertonoText.trackArtist),
      trailing: selected
          ? const Icon(
              Icons.check,
              key: Key('quality-check'),
              color: ApertonoColors.accent,
            )
          : null,
      onTap: onTap,
    );
  }
}
