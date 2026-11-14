import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../sleep_timer.dart';
import '../theme.dart';

/// Sleep timer selection sheet (FT-619).
class SleepTimerSheet extends StatelessWidget {
  const SleepTimerSheet({super.key, required this.timer});

  final SleepTimer timer;

  @override
  Widget build(BuildContext context) {
    final s = l10n(context);
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        final active = timer.active;
        final leftDuration = timer.left;
        final minutes = leftDuration == null
            ? 0
            : (leftDuration.inSeconds + 59) ~/ 60;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.sleepTimerTitle, style: ApertonoText.sectionTitle),
                    if (active)
                      TextButton(
                        key: const Key('sleep-off'),
                        onPressed: timer.cancel,
                        child: Text(s.sleepTimerTurnOff),
                      ),
                  ],
                ),
                if (active) ...[
                  const SizedBox(height: 4),
                  Text(
                    timer.endOfTrack
                        ? s.sleepTimerEndOfSong
                        : s.sleepTimerMinLeft(minutes),
                    style: ApertonoText.trackArtist,
                  ),
                ],
                const SizedBox(height: 12),
                ListTile(
                  key: const Key('sleep-15'),
                  minTileHeight: 48,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    s.sleepTimer15Min,
                    style: ApertonoText.trackTitle,
                  ),
                  onTap: () => timer.start(const Duration(minutes: 15)),
                ),
                ListTile(
                  key: const Key('sleep-30'),
                  minTileHeight: 48,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    s.sleepTimer30Min,
                    style: ApertonoText.trackTitle,
                  ),
                  onTap: () => timer.start(const Duration(minutes: 30)),
                ),
                ListTile(
                  key: const Key('sleep-45'),
                  minTileHeight: 48,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    s.sleepTimer45Min,
                    style: ApertonoText.trackTitle,
                  ),
                  onTap: () => timer.start(const Duration(minutes: 45)),
                ),
                ListTile(
                  key: const Key('sleep-60'),
                  minTileHeight: 48,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    s.sleepTimer60Min,
                    style: ApertonoText.trackTitle,
                  ),
                  onTap: () => timer.start(const Duration(minutes: 60)),
                ),
                ListTile(
                  key: const Key('sleep-end-of-track'),
                  minTileHeight: 48,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    s.sleepTimerEndOfSong,
                    style: ApertonoText.trackTitle,
                  ),
                  onTap: timer.untilEndOfTrack,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
