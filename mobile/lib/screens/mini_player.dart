import 'dart:async';

import 'package:flutter/material.dart';

import '../buffering_notice.dart';
import '../l10n/l10n.dart';
import '../playback.dart';
import '../player.dart';
import '../server_api.dart';
import '../theme.dart';
import 'parts.dart';

/// Subtitle line in mini-player. Failure reason in plain words:
/// indicates whether "retry" will help.
String statusText(Player player, AppLocalizations text) {
  return switch (player.phase) {
    AudioPhase.buffering =>
      player.searching ? text.miniSearchingSource : text.miniPreparingAudio,
    AudioPhase.playing => player.current?.artist ?? '',
    AudioPhase.paused => player.current?.artist ?? '',
    AudioPhase.idle => player.current?.artist ?? '',
    AudioPhase.error => switch (player.failure) {
      PlayFailure.noSource => text.miniNoSource,
      PlayFailure.unknownTrack => text.miniUnknownTrack,
      PlayFailure.noAccess => text.miniNoAccess,
      PlayFailure.noAnswer => text.miniNoAnswer,
      PlayFailure.dropped => text.miniDropped,
      PlayFailure.player || null => text.miniFailed,
    },
  };
}

/// Mini-player: cover artwork, title, progress bar, and single Play/Pause button.
///
/// While server is discovering source, bar is indeterminate: no accurate percentage.
/// Elapsed seconds since tap — beside text: timer runs only while waiting.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, required this.player, this.server, this.onOpen});

  final Player player;
  final ServerApi? server;
  final VoidCallback? onOpen;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  StreamSubscription<Duration>? _positions;
  Timer? _timer;
  var _position = Duration.zero;

  Player get _player => widget.player;

  @override
  void initState() {
    super.initState();
    _player.addListener(_changed);
    _positions = _player.positions.listen((position) {
      if (mounted) {
        setState(() => _position = position);
      }
    });
    _position = _player.position;
    _syncTimer();
  }

  @override
  void didUpdateWidget(MiniPlayer old) {
    super.didUpdateWidget(old);
    if (old.player != widget.player) {
      old.player.removeListener(_changed);
      _positions?.cancel();
      widget.player.addListener(_changed);
      _positions = widget.player.positions.listen((position) {
        if (mounted) {
          setState(() => _position = position);
        }
      });
      _position = widget.player.position;
    }
    _syncTimer();
  }

  @override
  void dispose() {
    _positions?.cancel();
    _player.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  void _changed() {
    _syncTimer();
    if (mounted) {
      setState(() {});
    }
  }

  void _syncTimer() {
    if (_player.phase == AudioPhase.buffering) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  double? _progress() {
    if (_player.phase == AudioPhase.buffering) {
      return null;
    }
    final duration = _player.duration;
    if (duration == null || duration.inMilliseconds <= 0) {
      return 0;
    }
    final value = _position.inMilliseconds / duration.inMilliseconds;
    return value.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final current = _player.current;
    if (current == null) {
      return const SizedBox.shrink();
    }
    final buffering = _player.phase == AudioPhase.buffering;
    final bufferingSince = _player.bufferingSince;
    final now = DateTime.now();
    final preparing =
        buffering &&
        showPreparing(
          since: bufferingSince,
          now: now,
          playedOnce: _player.playedOnce,
        );
    final text = l10n(context);
    // Brief buffering mid-song — subtitle unchanged, no flickering (FT-696).
    final status = buffering && !preparing
        ? current.artist
        : statusText(_player, text);
    final waited = preparing && bufferingSince != null
        ? now.difference(bufferingSince)
        : null;
    final server = widget.server;
    final radius = BorderRadius.circular(ApertonoRadii.row);
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: ApertonoColors.navGradient,
            borderRadius: radius,
            border: Border.all(color: ApertonoColors.border),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // Design: 85 dp circle around button. Gradient radius
                      // is computed from short side — height 68.
                      gradient: RadialGradient(
                        center: const Alignment(0.78, 0),
                        radius: 1.25,
                        stops: const [0, 0.55, 0.75],
                        colors: [
                          ApertonoColors.accent.withValues(alpha: 0.32),
                          ApertonoColors.accent.withValues(alpha: 0.06),
                          ApertonoColors.accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
                InkWell(
                  key: const Key('mini-player'),
                  borderRadius: radius,
                  onTap: widget.onOpen,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 68),
                    child: Padding(
                      // Top and bottom padding needed for large text: card
                      // expands, and without padding text would touch edge.
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              if (server != null)
                                SizedBox.square(
                                  dimension: 46,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          ApertonoRadii.cover,
                                        ),
                                        child: Cover(
                                          server: server,
                                          path: coverPath(current),
                                          artist: current.artist,
                                          size: 46,
                                        ),
                                      ),
                                      IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              ApertonoRadii.cover,
                                            ),
                                            border: Border.all(
                                              color: ApertonoColors.accent
                                                  .withValues(alpha: 0.6),
                                              width: 1.2,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      current.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ApertonoText.trackTitle.copyWith(
                                        color: ApertonoColors.textPrimary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (waited != null)
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              status,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: ApertonoText.trackArtist,
                                            ),
                                          ),
                                          Text(
                                            text.miniWaitSeconds(
                                              waited.inSeconds,
                                            ),
                                            key: const Key('play-wait'),
                                            style: ApertonoText.trackArtist,
                                          ),
                                        ],
                                      )
                                    else if (status.isNotEmpty)
                                      Text(
                                        status,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: ApertonoText.trackArtist,
                                      ),
                                    const SizedBox(height: 4),
                                    SizedBox(
                                      height: 2.5,
                                      width: double.infinity,
                                      child: LinearProgressIndicator(
                                        value: _progress(),
                                        minHeight: 2.5,
                                        borderRadius: BorderRadius.circular(
                                          ApertonoRadii.hairline,
                                        ),
                                        backgroundColor:
                                            ApertonoColors.progressTrack,
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                              ApertonoColors.accent,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              PlayPauseButton(
                                player: _player,
                                filled: true,
                                size: 44,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
