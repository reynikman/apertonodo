import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../lyrics.dart';
import '../theme.dart';

/// Song lyrics: current line is highlighted and visible, tapping seeks (FT-623).
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.lyrics,
    required this.positions,
    required this.onSeek,
    this.loading = false,
  });

  final Lyrics? lyrics;
  final Stream<Duration> positions;
  final void Function(Duration) onSeek;
  final bool loading;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  StreamSubscription<Duration>? _sub;
  int _current = -1;
  Duration _last = Duration.zero;
  late List<GlobalKey> _keys;

  @override
  void initState() {
    super.initState();
    _prepare();
    _listen();
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.positions != widget.positions) _listen();
    if (old.lyrics != widget.lyrics) {
      _prepare();
      _current = currentLine(_lines, _last);
    }
  }

  List<LyricLine> get _lines => widget.lyrics?.lines ?? const [];

  void _prepare() {
    _keys = List.generate(_lines.length, (_) => GlobalKey());
  }

  void _listen() {
    _sub?.cancel();
    _sub = widget.positions.listen((p) {
      _last = p;
      final i = currentLine(_lines, p);
      if (i == _current) return;
      setState(() => _current = i);
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    });
  }

  void _reveal() {
    if (!mounted || _current < 0 || _current >= _keys.length) return;
    final ctx = _keys[_current].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.4,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Widget _message(String text) => Center(
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: ApertonoText.trackArtist,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Center(
        child: CircularProgressIndicator(key: Key('lyrics-loading')),
      );
    }
    final t = l10n(context);
    final lyrics = widget.lyrics;
    if (lyrics == null || !lyrics.found) return _message(t.lyricsNone);
    if (lyrics.instrumental) return _message(t.lyricsInstrumental);
    // Thanks to the source (owner's decision 13.10): under any found lyrics.
    final credit = Padding(
      key: const Key('lyrics-credit'),
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(t.lyricsCredit, style: ApertonoText.trackArtist),
    );
    if (lyrics.lines.isEmpty) {
      return SingleChildScrollView(
        key: const Key('lyrics-plain'),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(lyrics.plain ?? '', style: ApertonoText.trackTitle),
            credit,
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < lyrics.lines.length; i++)
            InkWell(
              key: Key('lyric-$i'),
              onTap: () => widget.onSeek(lyrics.lines[i].at),
              child: Container(
                key: _keys[i],
                constraints: const BoxConstraints(minHeight: 48),
                alignment: Alignment.centerLeft,
                child: Text(
                  lyrics.lines[i].text,
                  style: ApertonoText.trackTitle.copyWith(
                    fontSize: 18,
                    height: 24 / 18,
                    fontWeight: i == _current
                        ? FontWeight.w700
                        : FontWeight.w400,
                    color: i == _current
                        ? ApertonoColors.textPrimary
                        : ApertonoColors.textSecondary,
                  ),
                ),
              ),
            ),
          credit,
        ],
      ),
    );
  }
}
