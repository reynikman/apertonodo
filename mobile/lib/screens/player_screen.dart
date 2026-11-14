import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../buffering_notice.dart';
import '../error_reports.dart';
import '../l10n/l10n.dart';
import '../lyrics.dart';
import '../models/track.dart';
import '../book_playback.dart';
import '../playback.dart';
import '../podcast_playback.dart';
import '../podcast_progress.dart' show podcastSpeeds;
import '../player.dart';
import '../server_api.dart';
import '../theme.dart';
import '../track_formats.dart';
import '../offline/download_queue.dart' show DownloadStatus;
import 'cover_glow.dart';
import 'mini_player.dart' show statusText;
import '../playback_speed.dart';
import '../podcast_downloads.dart';
import 'parts.dart';
import 'player_menu_sheet.dart';
import 'player_quick_row.dart';
import 'problem_sheet.dart';
import 'format_badge.dart';
import 'lyrics_sheet.dart';
import 'rating_controls.dart';
import 'sleep_timer_sheet.dart';
import 'skip_buttons.dart';
import 'speed_button.dart' hide speedLabel;
import 'spoken_controls.dart';

/// "1:05" from duration.
String clock(Duration value) {
  final seconds = value.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

ButtonStyle _circleStyle(double size) => IconButton.styleFrom(
  backgroundColor: ApertonoColors.surfaceRaised,
  foregroundColor: ApertonoColors.textPrimary,
  fixedSize: Size.square(size),
  minimumSize: Size.square(size),
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

const _hintShownKey = 'player-heart-hint-shown';

/// Podcast episode or book: they have their own player, it does not change.
bool _isSpoken(Track track) =>
    PodcastPlayback.isPodcast(track.id) || BookPlayback.isBook(track.id);

/// Catalog track identifier is UUID; only with it does server accept reports.
final _songId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.player,
    this.services,
    this.onDownload,
  });

  /// Screen listens to player instead of receiving track once on open: otherwise
  /// selecting another track would still show the old one.
  final Player player;

  /// Without server (player test harness) — header without heart.
  final Services? services;
  final Future<void> Function(Track track)? onDownload;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  final _queueScroll = ScrollController();
  final _headerKey = GlobalKey();
  // Lyrics of the song on screen (FT-843): one request per song serves both the dimmed
  // button and the sheet.
  String? _wordsFor;
  Future<Lyrics?>? _words;
  bool _wordsFailed = false;

  Future<Lyrics?> _wordsOf(ServerApi server, String id) {
    if (_wordsFor == id && _words != null) return _words!;
    final words = server.lyrics(id);
    _wordsFor = id;
    _words = words;
    _wordsFailed = false;
    words.then((answer) {
      if (identical(_words, words)) _wordsFailed = answer == null;
    }).ignore();
    return words;
  }

  final _dragOffset = ValueNotifier<double>(0.0);
  // Not `late`: an animation created for the first time in dispose looks for ancestor in
  // detached tree — Flutter 3.44 crashes on this.
  late final AnimationController _anim;
  Animation<double>? _dragAnim;
  bool _dismissDrag = false;
  bool _topBarDrag = false;
  double _pull = 0;
  late final _hearts = switch (widget.services) {
    final services? => Hearts(services.server),
    null => null,
  };

  /// What was scrolled to: row index and track itself. Index alone is not enough —
  /// going from 20th track of one album to 20th of another leaves index unchanged, but
  /// scrolling is needed: it is a different queue.
  String? _revealed;

  /// Which track was checked for favorites. Screen body rebuilds on
  /// every player notification — without guard server would be queried again.
  String? _asked;

  // Hint about long pressing the heart (FT-805): once per lifetime.
  final _heartLink = LayerLink();
  final _hintPortal = OverlayPortalController();
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    unawaited(_maybeShowHint());
  }

  Future<void> _maybeShowHint() async {
    final current = widget.player.current;
    if (widget.services?.ratings == null ||
        current == null ||
        _isSpoken(current) ||
        !_songId.hasMatch(current.id)) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || prefs.getBool(_hintShownKey) == true) {
      return;
    }
    await prefs.setBool(_hintShownKey, true);
    if (!mounted) {
      return;
    }
    _hintPortal.show();
    _hintTimer = Timer(const Duration(seconds: 6), _hideHint);
  }

  void _hideHint() {
    _hintTimer?.cancel();
    _hintTimer = null;
    if (_hintPortal.isShowing) {
      _hintPortal.hide();
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _anim.dispose();
    _dragOffset.dispose();
    _hearts?.dispose();
    _queueScroll.dispose();
    super.dispose();
  }

  void _askLiked(Track track) {
    final hearts = _hearts;
    if (hearts == null || track.id == _asked) {
      return;
    }
    _asked = track.id;
    unawaited(hearts.show([track]));
  }

  int _activePointers = 0;

  void _checkSettle() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_activePointers == 0 && _dragOffset.value > 0 && !_anim.isAnimating) {
        _finishDrag(0.0);
      }
    });
  }

  void _animateTo(double target, {VoidCallback? onComplete}) {
    _anim.stop();
    _anim.reset();
    final start = _dragOffset.value;
    if ((start - target).abs() < 0.5) {
      _dragOffset.value = target;
      _pull = target;
      onComplete?.call();
      return;
    }
    _dragAnim =
        Tween<double>(begin: start, end: target).animate(
          CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic),
        )..addListener(() {
          _dragOffset.value = _dragAnim!.value;
        });
    _anim.forward().then((_) {
      _pull = target;
      onComplete?.call();
    });
  }

  void _finishDrag(double velocity) {
    _dismissDrag = false;
    _topBarDrag = false;
    final current = _dragOffset.value;
    if (current <= 0) return;
    final height = MediaQuery.sizeOf(context).height;
    final shouldDismiss = current > height / 8 || velocity > 700;
    if (shouldDismiss) {
      _animateTo(
        height,
        onComplete: () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        },
      );
    } else {
      _animateTo(0.0);
    }
  }

  void _onTopBarDragStart(DragStartDetails details) {
    if (_queueScroll.hasClients && _queueScroll.offset > 0) {
      _topBarDrag = false;
      return;
    }
    _topBarDrag = true;
    _anim.stop();
    _pull = _dragOffset.value;
  }

  void _onTopBarDragUpdate(DragUpdateDetails details) {
    if (!_topBarDrag) return;
    _pull = max(0.0, _pull + details.delta.dy);
    _dragOffset.value = _pull;
  }

  void _onTopBarDragEnd(DragEndDetails details) {
    if (!_topBarDrag) return;
    _topBarDrag = false;
    _finishDrag(details.primaryVelocity ?? 0.0);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      // Scrolling queue to the top in same gesture does not mean closing player.
      _dismissDrag =
          notification.dragDetails != null && notification.metrics.pixels <= 0;
      if (_dismissDrag) {
        _anim.stop();
        _pull = _dragOffset.value;
      }
    } else if (notification is OverscrollNotification &&
        _dismissDrag &&
        notification.dragDetails != null &&
        notification.overscroll < 0) {
      _pull -= notification.overscroll;
      _dragOffset.value = _pull;
    } else if (notification is ScrollUpdateNotification &&
        _dismissDrag &&
        notification.dragDetails != null) {
      if (_dragOffset.value > 0) {
        final delta = notification.scrollDelta ?? 0.0;
        if (delta > 0) {
          _pull = max(0.0, _pull - delta);
          _dragOffset.value = _pull;
        }
      }
      if (notification.metrics.pixels > 0 && _dragOffset.value <= 0) {
        _dismissDrag = false;
      }
    } else if (notification is ScrollEndNotification) {
      if (_dismissDrag) {
        final velocity =
            notification.dragDetails?.velocity.pixelsPerSecond.dy ?? 0.0;
        _finishDrag(velocity);
      }
      _dismissDrag = false;
    }
    return false;
  }

  /// Playing queue row is visible, but only if user is currently
  /// viewing the queue.
  ///
  /// Header (cover, title, buttons) and queue are one scrollable
  /// list (phase M, as in owner screenshot). Former rule G55 "open
  /// on playing track" would scroll whole page, opening player
  /// without cover. Therefore: player always opens at top, on cover; and
  /// if user already scrolled to queue and track changes, playing
  /// track row stays in frame — which was why G55 was introduced.
  /// Rows are approximately 56 px: exact height is not calculated.
  void _revealPlaying(int index, String id) {
    final mark = '$index $id';
    if (index < 0 || mark == _revealed) {
      return;
    }
    _revealed = mark;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_queueScroll.hasClients) {
        return;
      }
      final header = _headerKey.currentContext?.size?.height ?? 0;
      if (_queueScroll.offset < header) {
        return;
      }
      const row = 56.0;
      final max = _queueScroll.position.maxScrollExtent;
      _queueScroll.jumpTo((header + index * row).clamp(0.0, max));
    });
  }

  void _scrollToQueue() {
    if (!_queueScroll.hasClients) return;
    final header = _headerKey.currentContext?.size?.height ?? 0;
    final max = _queueScroll.position.maxScrollExtent;
    _queueScroll.animateTo(
      header.clamp(0.0, max),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _showSpeedMenu(
    BuildContext context,
    PlaybackSpeed speedService,
  ) async {
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final position = renderBox != null && overlay != null
        ? RelativeRect.fromRect(
            renderBox.localToGlobal(Offset.zero, ancestor: overlay) &
                renderBox.size,
            Offset.zero & overlay.size,
          )
        : const RelativeRect.fromLTRB(0, 0, 0, 0);
    final currentSpeed = speedService.current ?? 1.0;
    final selected = await showMenu<double>(
      context: context,
      position: position,
      items: [
        for (final s in podcastSpeeds)
          PopupMenuItem<double>(
            key: ValueKey('speed-$s'),
            value: s,
            child: Text(
              speedLabel(s),
              style: TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontWeight: s == currentSpeed
                    ? FontWeight.w700
                    : FontWeight.w400,
                color: s == currentSpeed
                    ? ApertonoColors.accent
                    : ApertonoColors.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (selected != null) {
      unawaited(speedService.set(selected));
    }
  }

  Widget _heart(Hearts hearts, Track current) {
    final song = !_isSpoken(current);
    final ratings = widget.services?.ratings;
    final rate = song && ratings != null && _songId.hasMatch(current.id)
        ? () => showRatingSheet(context, ratings, current.id)
        : null;
    return ListenableBuilder(
      listenable: hearts,
      builder: (context, _) {
        final text = l10n(context);
        final liked = hearts.isLiked(current.id);
        final label = liked ? text.playerUnlike : text.playerLike;
        final button = IconButton(
          key: const Key('player-heart'),
          // Track long press is rating: IconButton tooltip would intercept
          // it, so track has its own tooltip without long press.
          tooltip: song ? null : label,
          isSelected: liked,
          // TalkBack label is on icon itself: track own tooltip
          // (below) does not land on button node.
          icon: Icon(Icons.favorite_border, semanticLabel: song ? label : null),
          selectedIcon: Icon(
            Icons.favorite,
            semanticLabel: song ? label : null,
          ),
          style: song
              ? IconButton.styleFrom(
                  foregroundColor: ApertonoColors.textPrimary,
                  fixedSize: const Size.square(48),
                  minimumSize: const Size.square(48),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )
              : _circleStyle(40),
          onPressed: () async {
            _hideHint();
            final messenger = ScaffoldMessenger.of(context);
            try {
              await hearts.toggle(current);
            } on ServerFailed catch (failed) {
              say(messenger, failureText(failed.reason));
            }
          },
        );
        if (!song) {
          return button;
        }
        return OverlayPortal(
          controller: _hintPortal,
          overlayChildBuilder: (_) => Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _heartLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              child: _HeartHint(text: text.playerHeartHint, onTap: _hideHint),
            ),
          ),
          child: CompositedTransformTarget(
            link: _heartLink,
            child: GestureDetector(
              onLongPress: rate == null
                  ? null
                  : () {
                      _hideHint();
                      rate();
                    },
              child: Tooltip(
                message: label,
                triggerMode: TooltipTriggerMode.manual,
                child: button,
              ),
            ),
          ),
        );
      },
    );
  }

  double _bottomBarHeight(BuildContext context) {
    final padding = MediaQuery.paddingOf(context).bottom;
    final hasTabs = widget.services != null;
    return 68 + 8 + (hasTabs ? 74 : 0) + padding;
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    // Dedicated pause in button row: cannot rely on mini-player — it slides
    // under tab buttons and might not be visible on this screen.
    return Listener(
      onPointerDown: (_) {
        _activePointers++;
      },
      onPointerUp: (_) {
        _activePointers = max(0, _activePointers - 1);
        if (_activePointers == 0) {
          _checkSettle();
        }
      },
      onPointerCancel: (_) {
        _activePointers = max(0, _activePointers - 1);
        if (_activePointers == 0) {
          _checkSettle();
        }
      },
      child: ValueListenableBuilder<double>(
        valueListenable: _dragOffset,
        builder: (context, offset, child) {
          final height = MediaQuery.sizeOf(context).height;
          final bottomBar = _bottomBarHeight(context);
          // Fully shown by the point where letting go closes the player.
          final revealed = offset <= 0 ? 0.0 : min(1.0, offset / (height / 8));
          return PlayerBarReveal(
            key: const Key('player-bar-reveal'),
            revealed: revealed,
            barHeight: bottomBar,
            child: Transform.translate(offset: Offset(0, offset), child: child),
          );
        },
        child: ListenableBuilder(
          listenable: player,
          builder: (context, _) {
            final current = player.current;
            final hearts = _hearts;
            if (hearts != null && current != null) {
              _askLiked(current);
            }
            final text = l10n(context);
            return Scaffold(
              key: const Key('player-screen'),
              body: Stack(
                children: [
                  Positioned.fill(
                    child: current == null
                        ? Center(child: Text(text.playerNoTrack))
                        : _playing(context, player, current),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: _topBar(context, current, hearts),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, Track? current, Hearts? hearts) {
    final text = l10n(context);
    final services = widget.services;
    final onDownload = widget.onDownload;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onTopBarDragStart,
      onVerticalDragUpdate: _onTopBarDragUpdate,
      onVerticalDragEnd: _onTopBarDragEnd,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            IconButton(
              key: const Key('player-close'),
              tooltip: text.playerCollapse,
              style: _circleStyle(40),
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const Spacer(),
            if (hearts != null && current != null && _isSpoken(current))
              _heart(hearts, current),
            if (current != null &&
                (services != null ||
                    (onDownload != null && _isSpoken(current)))) ...[
              const SizedBox(width: 8),
              if (_isSpoken(current))
                PopupMenuButton<VoidCallback>(
                  key: const Key('player-menu'),
                  tooltip: text.playerMore,
                  style: _circleStyle(40),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) => action(),
                  itemBuilder: (context) => [
                    // FT-863: no artist, album or playlist for an episode or a
                    // book — they led into the music catalogue by the show's name.
                    if (services?.openPodcast case final openPodcast?
                        when PodcastPlayback.isPodcast(current.id))
                      PopupMenuItem(
                        key: const Key('player-to-podcast'),
                        value: () => openPodcast(current),
                        child: Text(text.playerToPodcast),
                      ),
                    if (onDownload != null && _isSpoken(current))
                      PopupMenuItem(
                        key: const Key('download-track'),
                        value: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          await onDownload(current);
                          say(messenger, text.playerAddedToDownloads);
                        },
                        child: Text(text.playerDownload),
                      ),
                    if (services?.sleepTimer case final sleep?
                        when _isSpoken(current))
                      PopupMenuItem(
                        key: const Key('player-sleep'),
                        value: () => showModalBottomSheet<void>(
                          context: context,
                          useRootNavigator: true,
                          isScrollControlled: true,
                          builder: (_) => SingleChildScrollView(
                            child: SleepTimerSheet(timer: sleep),
                          ),
                        ),
                        child: Text(text.sleepTimerTitle),
                      ),
                    if (services?.ratings case final ratings?
                        when _songId.hasMatch(current.id))
                      PopupMenuItem(
                        key: const Key('player-rate'),
                        value: () =>
                            showRatingSheet(context, ratings, current.id),
                        child: Text(text.playerRate),
                      ),
                    // Report identifies track by ID: podcast episode does not have one.
                    if (services != null && _songId.hasMatch(current.id))
                      PopupMenuItem(
                        key: const Key('player-problem'),
                        value: () => showProblemSheet(
                          context,
                          services.server,
                          place: ProblemPlace.player,
                          trackId: current.id,
                        ),
                        child: Text(text.problemTitle),
                      ),
                  ],
                )
              else
                IconButton(
                  key: const Key('player-menu'),
                  tooltip: text.playerMore,
                  style: _circleStyle(40),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => showPlayerMenuSheet(
                    context,
                    player: widget.player,
                    current: current,
                    services: services,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _playing(BuildContext context, Player player, Track current) {
    final queue = player.queue;
    final numbered =
        queue.length > 1 &&
        queue.first.artworkUrl.isNotEmpty &&
        queue.every((track) => track.artworkUrl == queue.first.artworkUrl);
    _revealPlaying(player.queueIndex, current.id);
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.builder(
        key: const Key('queue'),
        controller: _queueScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 48,
          bottom: 24,
        ),
        itemCount: queue.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return KeyedSubtree(
              key: _headerKey,
              child: _nowPlaying(context, player, current),
            );
          }
          final song = index - 1;
          final track = queue[song];
          return _QueueRow(
            index: song,
            track: track,
            server: widget.services?.server,
            numbered: numbered,
            selected: song == player.queueIndex,
            last: song == queue.length - 1,
            onTap: () => player.jump(song),
          );
        },
      ),
    );
  }

  /// Cover, title, seek bar, and buttons — in same list as queue.
  /// "-15 / +30 s" for podcast episode: clamped to start and end.
  Widget _skip(Player player, SkipKind kind, SkipTexts texts) => SkipButton(
    key: ValueKey('player-skip-${kind.name}'),
    kind: kind,
    texts: texts,
    onPressed: () => unawaited(
      player.seek(skipTarget(player.position, kind, player.duration)),
    ),
  );

  /// Artist with file format badge on the right (FT-633). Unknown format —
  /// row remains identical to what it was before badge.
  Widget _withFormat(TrackFormats? formats, String trackId, Widget artist) {
    if (formats == null) return artist;
    return ListenableBuilder(
      listenable: formats,
      builder: (context, _) {
        final format = formats.of(trackId);
        if (format == null) return artist;
        return Row(
          children: [
            Flexible(child: artist),
            const SizedBox(width: 8),
            FormatBadge(key: const Key('player-format'), format: format),
          ],
        );
      },
    );
  }

  /// Remaining time to end of book: rest of current part plus durations
  /// of subsequent parts of same book in queue.
  String? _bookRemaining(
    Player player,
    Track current,
    Duration position,
    AppLocalizations text,
  ) {
    final currentTotalMs =
        player.duration?.inMilliseconds ?? current.durationMs;
    if (currentTotalMs <= 0) return null;
    final currentLeftMs = max(0, currentTotalMs - position.inMilliseconds);
    var totalMs = currentLeftMs;

    final parsed = BookPlayback.parseId(current.id);
    final bookId = parsed?.$1;
    final queue = player.queue;
    final index =
        player.queueIndex >= 0 &&
            player.queueIndex < queue.length &&
            queue[player.queueIndex].id == current.id
        ? player.queueIndex
        : queue.indexWhere((t) => t.id == current.id);

    if (index >= 0) {
      for (var i = index + 1; i < queue.length; i++) {
        final t = queue[i];
        final isSameBook = bookId != null
            ? (BookPlayback.parseId(t.id)?.$1 == bookId)
            : BookPlayback.isBook(t.id);
        if (isSameBook) {
          totalMs += t.durationMs;
        }
      }
    }

    final totalMinutes = totalMs ~/ 60000;
    if (totalMinutes < 60) {
      return text.spokenRemainingMinutes(totalMinutes);
    }
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    return text.spokenRemainingHoursMinutes(hours, minutes);
  }

  Widget _quickRow(BuildContext context, Track current, Services? services) {
    final text = l10n(context);
    final onDownload = widget.onDownload;
    final sleep = services?.sleepTimer;
    final downloads = services?.downloads;
    final words = services != null && _songId.hasMatch(current.id)
        ? _wordsOf(services.server, current.id)
        : null;
    return ListenableBuilder(
      listenable: Listenable.merge([?sleep, ?downloads]),
      builder: (context, _) => FutureBuilder<Lyrics?>(
        future: words,
        builder: (context, answer) => PlayerQuickRow(
          lyricsMissing: words != null && lyricsMissing(answer.data),
          downloadTooltip: text.playerDownload,
          lyricsTooltip: text.playerLyrics,
          sleepTooltip: text.sleepTimerTitle,
          downloaded: downloads?.statusOf(current.id) == DownloadStatus.done,
          sleepActive: sleep?.active ?? false,
          onDownload: onDownload == null
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await onDownload(current);
                  say(messenger, text.playerAddedToDownloads);
                },
          onLyrics: words == null
              ? null
              : () {
                  // The earlier request got no answer at all — ask again on tap.
                  if (_wordsFailed) setState(() => _words = null);
                  showLyricsSheet(
                    context,
                    _wordsOf(services!.server, current.id),
                    widget.player,
                  );
                },
          onSleep: sleep == null
              ? null
              : () => showModalBottomSheet<void>(
                  context: context,
                  useRootNavigator: true,
                  isScrollControlled: true,
                  builder: (_) => SingleChildScrollView(
                    child: SleepTimerSheet(timer: sleep),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _nowPlaying(BuildContext context, Player player, Track current) {
    final text = l10n(context);
    final services = widget.services;
    final isPodcast = PodcastPlayback.isPodcast(current.id);
    final isBook = BookPlayback.isBook(current.id);
    final spoken = isPodcast || isBook;
    final hearts = _hearts;
    final skipTexts = SkipTexts(
      back: text.playerSkipBack,
      forward: text.playerSkipForward,
    );
    final size = MediaQuery.sizeOf(context);
    // On low height cover does not fit; in landscape orientation its
    // spot is taken by queue.
    final showCover = services != null && size.height >= 450;
    final coverSize = min(320.0, min(size.width - 88, size.height * 0.36));
    final toggleColor = WidgetStateProperty.resolveWith<Color>(
      (states) => states.contains(WidgetState.selected)
          ? ApertonoColors.accent
          : ApertonoColors.textPrimary,
    );
    final toggleStyle = ButtonStyle(
      foregroundColor: toggleColor,
      iconColor: toggleColor,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        if (services != null && showCover)
          Center(
            child: CoverGlow(
              key: const Key('player-cover'),
              image: coverPath(current) == null
                  ? null
                  : NetworkImage(
                      services.server.url(coverPath(current)!),
                      headers: services.server.headers,
                    ),
              size: coverSize,
              child: Cover(
                server: services.server,
                path: coverPath(current),
                artist: current.artist,
                size: coverSize,
                radius: ApertonoRadii.medium,
              ),
            ),
          ),
        const SizedBox(height: 24),
        if (hearts != null && !spoken)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
            child: Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        current.title,
                        key: const Key('player-title'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: ApertonoFonts.sans,
                          fontSize: 22,
                          height: 28 / 22,
                          fontWeight: FontWeight.w700,
                          color: ApertonoColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _withFormat(
                        services?.formats,
                        current.id,
                        InkWell(
                          onTap: switch (services?.openArtist) {
                            final open? => () => open(current.artist),
                            null => null,
                          },
                          child: Text(
                            current.artist,
                            key: const Key('player-artist'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: ApertonoFonts.sans,
                              fontSize: 15,
                              height: 19 / 15,
                              color: ApertonoColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _heart(hearts, current),
              ],
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              current.title,
              key: const Key('player-title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: ApertonoFonts.sans,
                fontSize: 22,
                height: 28 / 22,
                fontWeight: FontWeight.w700,
                color: ApertonoColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _withFormat(
              services?.formats,
              current.id,
              InkWell(
                onTap: switch (services?.openArtist) {
                  final open? => () => open(current.artist),
                  null => null,
                },
                child: Text(
                  current.artist,
                  key: const Key('player-artist'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: ApertonoFonts.sans,
                    fontSize: 15,
                    height: 19 / 15,
                    color: ApertonoColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        SeekBar(player: player),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: spoken
                ? MainAxisAlignment.spaceBetween
                : MainAxisAlignment.center,
            spacing: spoken ? 0 : 10,
            children: [
              // Episode shows speed instead of shuffle (FT-730).
              if (spoken && services?.speed?.current != null)
                ListenableBuilder(
                  listenable: services!.speed!,
                  builder: (context, _) => SpeedButton(
                    key: const Key('player-speed'),
                    speed: services.speed!.current ?? 1.0,
                    speeds: podcastSpeeds,
                    tooltip: text.playerSpeed,
                    onSelected: (v) => unawaited(services.speed!.set(v)),
                  ),
                )
              else
                IconButton(
                  key: const Key('shuffle-button'),
                  tooltip: text.playerShuffle,
                  isSelected: player.shuffle,
                  style: toggleStyle,
                  icon: const Icon(Icons.shuffle),
                  onPressed: player.toggleShuffle,
                ),
              // Podcast episode skipped by seconds rather than tracks (Р-A100).
              if (spoken)
                _skip(player, SkipKind.back, skipTexts)
              else
                IconButton(
                  key: const Key('previous-button'),
                  tooltip: text.playerPrevious,
                  style: _circleStyle(52),
                  icon: const Icon(Icons.skip_previous),
                  onPressed: player.previous,
                ),
              // Dedicated pause rather than relying on mini-player: mini-player slides
              // under tab buttons, leaving player screen without pause.
              PlayPauseButton(
                player: player,
                prefix: 'player-',
                tooltips: true,
                filled: true,
                size: 64,
                iconSize: 32,
              ),
              if (spoken)
                _skip(player, SkipKind.forward, skipTexts)
              else
                IconButton(
                  key: const Key('next-button'),
                  tooltip: text.playerNext,
                  style: _circleStyle(52),
                  icon: const Icon(Icons.skip_next),
                  onPressed: player.hasNext ? player.next : null,
                ),
              IconButton(
                key: const Key('repeat-button'),
                tooltip: switch (player.repeat) {
                  Repeat.off => text.playerRepeatOff,
                  Repeat.all => text.playerRepeatAll,
                  Repeat.one => text.playerRepeatOne,
                },
                isSelected: player.repeat != Repeat.off,
                style: toggleStyle,
                icon: Icon(
                  player.repeat == Repeat.one ? Icons.repeat_one : Icons.repeat,
                ),
                onPressed: () {
                  player.cycleRepeat();
                  // The icon alone does not say which repeat is on (FT-849).
                  final messenger = ScaffoldMessenger.of(context)
                    ..removeCurrentSnackBar();
                  say(messenger, switch (player.repeat) {
                    Repeat.off => text.playerRepeatOff,
                    Repeat.all => text.playerRepeatAll,
                    Repeat.one => text.playerRepeatOne,
                  });
                },
              ),
            ],
          ),
        ),
        if (spoken) ...[
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: Listenable.merge([
              if (services?.speed != null) services!.speed!,
              if (services?.sleepTimer != null) services!.sleepTimer!,
              if (services?.podcastDownloads != null)
                services!.podcastDownloads!,
            ]),
            builder: (context, _) {
              final speedService = services?.speed;
              final sleepTimerService = services?.sleepTimer;
              final currentSpeed = speedService?.current ?? 1.0;
              final sleepActive = sleepTimerService?.active ?? false;
              final podcastDownloads = services?.podcastDownloads;
              final downloadState =
                  podcastDownloads?.stateOf(current.id) ??
                  EpisodeDownloadState.none;
              final download = switch (downloadState) {
                EpisodeDownloadState.downloading => SpokenDownload.downloading,
                EpisodeDownloadState.onPhone => SpokenDownload.done,
                _ => SpokenDownload.none,
              };
              final spokenTexts = SpokenTexts(
                skip: skipTexts,
                speed: text.spokenSpeed,
                download: text.spokenDownload,
                downloaded: text.spokenDownloaded,
                sleep: text.spokenSleep,
                queue: text.spokenQueue,
                parts: text.spokenParts,
                remaining: text.spokenRemaining,
              );

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Builder(
                  builder: (tileContext) {
                    final onSpeed = speedService != null
                        ? () => _showSpeedMenu(tileContext, speedService)
                        : null;
                    final onSleep = sleepTimerService != null
                        ? () => showModalBottomSheet<void>(
                            context: context,
                            useRootNavigator: true,
                            isScrollControlled: true,
                            builder: (_) => SingleChildScrollView(
                              child: SleepTimerSheet(timer: sleepTimerService),
                            ),
                          )
                        : null;

                    if (isBook) {
                      return StreamBuilder<Duration>(
                        stream: player.positions,
                        initialData: player.position,
                        builder: (context, snapshot) {
                          final position = snapshot.data ?? player.position;
                          final remaining = _bookRemaining(
                            player,
                            current,
                            position,
                            text,
                          );
                          return SpokenTiles(
                            kind: SpokenKind.book,
                            speed: currentSpeed,
                            onSpeed: onSpeed,
                            sleepActive: sleepActive,
                            onSleep: onSleep,
                            onParts: _scrollToQueue,
                            remaining: remaining,
                            texts: spokenTexts,
                          );
                        },
                      );
                    }

                    return SpokenTiles(
                      kind: SpokenKind.podcast,
                      speed: currentSpeed,
                      onSpeed: onSpeed,
                      sleepActive: sleepActive,
                      onSleep: onSleep,
                      onQueue: _scrollToQueue,
                      download: download,
                      onDownload:
                          download == SpokenDownload.none &&
                              podcastDownloads != null
                          ? () async {
                              podcastDownloads.describeTrack(
                                current.id,
                                title: current.title,
                                show: current.artist,
                                durationMs: current.durationMs > 0
                                    ? current.durationMs
                                    : null,
                                image: current.artworkUrl.isEmpty
                                    ? null
                                    : current.artworkUrl,
                              );
                              final res = await podcastDownloads
                                  .downloadEpisode(current.id);
                              if (!context.mounted) return;
                              final messenger = ScaffoldMessenger.of(context);
                              switch (res) {
                                case EpisodeDownloadResult.started:
                                case EpisodeDownloadResult.alreadyThere:
                                  break;
                                case EpisodeDownloadResult.noRoom:
                                  say(messenger, text.podcastNoRoom);
                                case EpisodeDownloadResult.metered:
                                  say(messenger, text.podcastMetered);
                                case EpisodeDownloadResult.badUrl:
                                  say(messenger, text.podcastDownloadFailed);
                              }
                            }
                          : null,
                      texts: spokenTexts,
                    );
                  },
                ),
              );
            },
          ),
        ],
        if (!spoken) _quickRow(context, current, services),
        // Below is entire queue including played tracks; "Up Next" read like button.
        if (player.phase == AudioPhase.error && services != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ReportButton(
              key: ValueKey((current.id, player.failure)),
              server: services.server,
              report: ErrorReport(
                kind:
                    'play.${reportName((player.failure ?? PlayFailure.player).name)}',
                screen: 'player',
              ),
              problem: ProblemReport(
                reason: 'no_play',
                place: ProblemPlace.player,
                trackId: current.id,
                appVersion: problemAppVersion,
                text: 'play.${(player.failure ?? PlayFailure.player).name}',
              ),
            ),
          ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Material(
            key: const Key('queue-heading'),
            color: ApertonoColors.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(ApertonoRadii.xLarge),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: Text(text.playerQueue, style: ApertonoText.trackArtist),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Amber bubble pointing to heart (FT-805). Tapping it dismisses it;
/// taps outside interact with screen as usual.
class _HeartHint extends StatelessWidget {
  const _HeartHint({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        key: const Key('player-heart-hint'),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: CustomPaint(size: const Size(12, 6), painter: _HintTail()),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 230),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: ApertonoColors.accent,
                  borderRadius: BorderRadius.all(
                    Radius.circular(ApertonoRadii.album),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    text,
                    style: const TextStyle(
                      fontFamily: ApertonoFonts.sans,
                      fontSize: 12.5,
                      height: 16 / 12.5,
                      color: ApertonoColors.inkOnLight,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HintTail extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height)
        ..lineTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..close(),
      Paint()..color = ApertonoColors.accent,
    );
  }

  @override
  bool shouldRepaint(_HintTail oldDelegate) => false;
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.index,
    required this.track,
    required this.server,
    required this.numbered,
    required this.selected,
    required this.last,
    required this.onTap,
  });

  final int index;
  final Track track;
  final ServerApi? server;
  final bool numbered;
  final bool selected;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final server = this.server;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        key: Key('queue-row-$index'),
        color: ApertonoColors.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: last
            ? const BorderRadius.vertical(
                bottom: Radius.circular(ApertonoRadii.xLarge),
              )
            : null,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  if (numbered) ...[
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: ApertonoText.time.copyWith(
                          color: selected
                              ? ApertonoColors.accent
                              : ApertonoColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ] else if (server != null) ...[
                    Cover(
                      server: server,
                      path: coverPath(track),
                      artist: track.artist,
                      size: 40,
                      radius: 6,
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ApertonoText.trackTitle.copyWith(
                            color: selected
                                ? ApertonoColors.accent
                                : ApertonoColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ApertonoText.trackArtist,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    formatDuration(track.durationMs),
                    style: ApertonoText.time.copyWith(
                      color: ApertonoColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Seek bar: tracks audio playback, seeks when released.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.player});

  final Player player;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  /// While dragging seek bar, it follows touch rather than audio.
  double? _dragging;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayerChanged);
    _syncTimer();
  }

  @override
  void didUpdateWidget(SeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChanged);
      widget.player.addListener(_onPlayerChanged);
    }
    _syncTimer();
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _onPlayerChanged() {
    _syncTimer();
    if (mounted) setState(() {});
  }

  void _syncTimer() {
    if (widget.player.phase == AudioPhase.buffering) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = l10n(context);
    final player = widget.player;
    final bufferingSince = player.bufferingSince;
    // Before first audio — immediately; mid-track — after 1.5s (FT-696).
    final buffering =
        player.phase == AudioPhase.buffering &&
        showPreparing(
          since: bufferingSince,
          now: DateTime.now(),
          playedOnce: player.playedOnce,
        );
    final waited = buffering && bufferingSince != null
        ? DateTime.now().difference(bufferingSince)
        : Duration.zero;

    return StreamBuilder<Duration>(
      stream: player.positions,
      builder: (context, snapshot) {
        final total = player.duration ?? Duration.zero;
        final max = total.inMilliseconds.toDouble();
        final heard = (snapshot.data ?? player.position).inMilliseconds
            .toDouble();
        final value = (_dragging ?? heard).clamp(0.0, max > 0 ? max : 0.0);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: ApertonoColors.accent,
                  thumbColor: ApertonoColors.accent,
                  inactiveTrackColor: ApertonoColors.borderStrong,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 16,
                  ),
                ),
                child: Slider(
                  key: const Key('seek-bar'),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  max: max > 0 ? max : 1,
                  value: value,
                  onChanged: max > 0
                      ? (next) => setState(() => _dragging = next)
                      : null,
                  onChangeEnd: (end) {
                    setState(() => _dragging = null);
                    player.seek(Duration(milliseconds: end.round()));
                  },
                ),
              ),
              if (buffering)
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        statusText(player, text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ApertonoText.time.copyWith(
                          color: ApertonoColors.textSecondary,
                        ),
                      ),
                    ),
                    Text(
                      text.playerWaitSeconds(waited.inSeconds),
                      key: const Key('player-wait'),
                      style: ApertonoText.time.copyWith(
                        color: ApertonoColors.textSecondary,
                      ),
                    ),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      clock(Duration(milliseconds: value.round())),
                      key: const Key('seek-position'),
                      style: ApertonoText.time.copyWith(
                        color: ApertonoColors.textSecondary,
                      ),
                    ),
                    Text(
                      clock(total),
                      key: const Key('seek-total'),
                      style: ApertonoText.time.copyWith(
                        color: ApertonoColors.textSecondary,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Lets the bottom bar (mini player and tabs) under the full player come in
/// with the drag (FT-851): the strip of the player above the bar fades out as
/// [revealed] goes from 0 to 1. Before, the strip was cut off whole on the
/// first pixel of the drag and the bar popped in.
class PlayerBarReveal extends SingleChildRenderObjectWidget {
  const PlayerBarReveal({
    super.key,
    required this.revealed,
    required this.barHeight,
    super.child,
  });

  /// 0 — the player covers the bar, 1 — the bar is fully visible.
  final double revealed;
  final double barHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBarReveal(revealed, barHeight);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderBarReveal)
      ..revealed = revealed
      ..barHeight = barHeight;
  }
}

class _RenderBarReveal extends RenderProxyBox {
  _RenderBarReveal(this._revealed, this._barHeight);

  double _revealed;
  set revealed(double value) {
    if (value == _revealed) return;
    _revealed = value;
    markNeedsPaint();
  }

  double _barHeight;
  set barHeight(double value) {
    if (value == _barHeight) return;
    _barHeight = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  /// Once the bar shows through, taps on it go to the bar, not to the
  /// fading strip of the player above it.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_revealed > 0 && position.dy >= size.height - _barHeight) {
      return false;
    }
    return super.hitTest(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    // At rest there is nothing to fade: no extra layer under the player.
    if (_revealed <= 0 || size.height <= _barHeight) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    final edge = (size.height - _barHeight) / size.height;
    // Only the alpha of the mask matters: opaque keeps the player, clear
    // lets the bar through.
    const solid = ApertonoColors.scrim;
    final strip = solid.withValues(alpha: 1 - _revealed);
    final mask = (layer as ShaderMaskLayer?) ?? ShaderMaskLayer();
    mask
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [solid, solid, strip, strip],
        stops: [0, edge, edge, 1],
      ).createShader(Offset.zero & size)
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    layer = mask;
    context.pushLayer(mask, super.paint, offset);
  }
}
