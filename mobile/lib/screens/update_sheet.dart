import 'package:flutter/material.dart';

import '../app_update.dart';
import '../l10n/l10n.dart';
import '../theme.dart';

/// "Update available" sheet (FT-628). Listens to [AppUpdate].
class UpdateSheet extends StatelessWidget {
  const UpdateSheet({super.key, required this.update});

  final AppUpdate update;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        final info = update.available;
        if (info == null) return const SizedBox.shrink();
        final text = l10n(context);
        final downloading = update.phase == UpdatePhase.downloading;
        // Build number after "+" is not shown to user.
        final version = info.version.split('+').first;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text.updateTitle, style: ApertonoText.sectionTitle),
              const SizedBox(height: 4),
              Text(
                text.updateVersion(version),
                style: ApertonoText.trackArtist,
              ),
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(info.notes, style: ApertonoText.trackTitle),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (update.phase == UpdatePhase.failed) ...[
                Text(
                  text.updateFailed,
                  style: ApertonoText.trackArtist.copyWith(
                    color: ApertonoColors.error,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (downloading) ...[
                LinearProgressIndicator(
                  key: const Key('update-progress'),
                  value: update.progress,
                ),
                const SizedBox(height: 8),
                Text(
                  text.updateDownloading((update.progress * 100).round()),
                  style: ApertonoText.trackArtist,
                ),
              ] else ...[
                FilledButton(
                  key: const Key('update-install'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: update.install,
                  child: Text(text.updateInstall),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('update-skip'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: update.skip,
                  child: Text(text.updateSkip),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
