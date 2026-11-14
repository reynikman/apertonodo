import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme.dart';

/// File format badge (FT-633, P-A94): `flac` → `FLAC`.
///
/// Shows only known formats from [_known]; `null`, empty string, or
/// unknown word renders nothing (no `Text` widgets) to ensure neither
/// release name nor source link appears in badge. For screen reader —
/// `Semantics` with label "Format: FLAC"; `excludeSemantics` prevents reading
/// text twice.
class FormatBadge extends StatelessWidget {
  const FormatBadge({super.key, required this.format});

  final String? format;

  static const _known = <String>{
    'FLAC',
    'MP3',
    'OPUS',
    'AAC',
    'OGG',
    'M4A',
    'WAV',
    'ALAC',
    'APE',
    'WV',
  };

  @override
  Widget build(BuildContext context) {
    final label = format?.trim().toUpperCase() ?? '';
    if (!_known.contains(label)) return const SizedBox.shrink();
    return Semantics(
      label: l10n(context).formatBadgeSpoken(label),
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ApertonoColors.surfaceRaised,
          border: Border.all(color: ApertonoColors.borderStrong),
          borderRadius: BorderRadius.circular(ApertonoRadii.album),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Text(
            label,
            style: ApertonoText.trackArtist.copyWith(
              color: ApertonoColors.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),
    );
  }
}
