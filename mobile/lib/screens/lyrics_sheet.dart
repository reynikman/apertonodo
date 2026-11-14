import 'dart:async';

import 'package:flutter/material.dart';

import '../lyrics.dart';
import '../playback.dart';
import '../player.dart';
import '../screen_awake.dart';
import 'lyrics_view.dart';

/// Song lyrics sheet (FT-623): opens from player menu. Lyrics are fetched
/// from lyrics extension (FT-620/624); line is highlighted as song plays,
/// tapping line seeks to it. [words] is the request the player has already made for this
/// song: the sheet does not repeat it.
Future<void> showLyricsSheet(
  BuildContext context,
  Future<Lyrics?> words,
  Player player,
) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  builder: (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.8,
    child: LyricsSheet(words: words, player: player),
  ),
);

class LyricsSheet extends StatefulWidget {
  const LyricsSheet({super.key, required this.words, required this.player});

  final Future<Lyrics?> words;
  final Player player;

  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  @override
  Widget build(BuildContext context) => SafeArea(
    // The screen stays on only while the song is playing (FT-843): on pause it goes dark
    // as usual.
    child: ListenableBuilder(
      listenable: widget.player,
      builder: (context, child) => KeepScreenOn(
        on: widget.player.phase == AudioPhase.playing,
        child: child!,
      ),
      child: FutureBuilder<Lyrics?>(
        future: widget.words,
        builder: (context, words) => LyricsView(
          lyrics: words.data,
          loading: words.connectionState != ConnectionState.done,
          positions: widget.player.positions,
          onSeek: (to) => unawaited(widget.player.seek(to)),
        ),
      ),
    ),
  );
}
