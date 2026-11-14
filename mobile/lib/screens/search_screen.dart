import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../catalog.dart';
import '../l10n/l10n.dart';
import '../models/track.dart';
import '../recent_queries.dart';
import '../server_api.dart';
import '../theme.dart';
import 'artist_avatar.dart';
import 'parts.dart';

/// Message to display instead of results. Previously any error appeared as "nothing
/// found" — empty list without a single word.
String searchFailureText(SearchFailure failure, AppLocalizations text) {
  return switch (failure) {
    SearchFailure.noAccess => text.searchFailureNoAccess,
    SearchFailure.catalogDown => text.searchFailureCatalogDown,
    SearchFailure.tooMany => text.searchFailureTooMany,
    SearchFailure.noAnswer => text.searchFailureNoAnswer,
  };
}

class SearchScreen extends StatefulWidget {
  /// Pause between keystroke and suggestions. A user types faster than
  /// the network responds: without a pause, every word triggers extra requests,
  /// and the last to arrive might not be the intended one.
  static const typingPause = Duration(milliseconds: 200);

  const SearchScreen({
    super.key,
    required this.onSearch,
    required this.onSelect,
    this.onResults,
    this.onSuggest,
    this.onArtist,
    this.recent,
    this.services,
    this.query = '',
    this.active,
    this.again,
  });

  final Future<SearchResult> Function(String query) onSearch;

  /// Track at [index] selected: play it, and search results become the queue.
  final void Function(List<Track> tracks, int index) onSelect;

  /// Results arrived: prepare the first track while the user is reading.
  final ValueChanged<List<Track>>? onResults;

  /// Suggestions while typing. If null, screen works as before, on search submit.
  final Future<List<String>> Function(String query)? onSuggest;

  /// Artist selected: open artist page instead of playing.
  final ValueChanged<String>? onArtist;

  /// Recent queries. Stored on device: server does not store query text.
  final RecentQueries? recent;

  /// Hearts and playlists. Without server: bare results, testing wrapper.
  final Services? services;

  /// Immediate search query: top track from artist page.
  final String query;

  /// Tab is active: empty field focuses after frame; inactive does not.
  final ValueListenable<bool>? active;

  /// Second tap on active Search tab: clear text, focus field,
  /// scroll to top, starting fresh (B-3).
  final Listenable? again;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final _field = TextEditingController(text: widget.query);
  final _focus = FocusNode();
  final _scroll = ScrollController();
  late final _hearts = switch (widget.services) {
    final services? => Hearts(services.server),
    null => null,
  };
  SearchResult _results = const SearchResult();
  var _loading = false;
  var _searched = false;
  SearchFailure? _failure;
  var _request = 0;
  List<String> _suggestions = const [];
  var _suggestRequest = 0;
  Timer? _typing;
  Timer? _historyTimer;
  List<String> _recent = const [];
  List<Track> _heardTracks = const [];

  @override
  void initState() {
    super.initState();
    widget.active?.addListener(_onActive);
    widget.again?.addListener(_again);
    _onActive();
    if (widget.query.isNotEmpty) {
      unawaited(Future.microtask(() => _run(widget.query)));
    }
    final recent = widget.recent;
    if (recent != null) {
      unawaited(recent.load().then(_showRecent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _historyTimer = Timer(Duration.zero, () => unawaited(_loadHistory()));
      }
    });
  }

  @override
  void dispose() {
    widget.active?.removeListener(_onActive);
    widget.again?.removeListener(_again);
    _typing?.cancel();
    _historyTimer?.cancel();
    _field.dispose();
    _focus.dispose();
    _scroll.dispose();
    _hearts?.dispose();
    super.dispose();
  }

  void _onActive() {
    if (widget.active?.value != true) {
      _focus.unfocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active?.value == true && _field.text.isEmpty) {
        _focus.requestFocus();
      }
    });
  }

  void _again() {
    _clear();
    _focus.requestFocus();
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  void _showRecent(List<String> queries) {
    if (mounted) {
      setState(() => _recent = queries);
    }
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    final server = widget.services?.server;
    if (server == null) {
      return;
    }
    Chunk<Listen> history;
    try {
      history = await server.history();
    } catch (_) {
      return;
    }
    if (!mounted) {
      return;
    }
    final rows = [
      for (final row in history.items)
        if (!row.testTone) row,
    ];
    final tracks = <String, Track>{};
    for (final row in rows) {
      tracks.putIfAbsent(
        '${row.track.artist}\u0000${row.track.title}',
        () => row.track,
      );
    }
    setState(() => _heardTracks = tracks.values.take(4).toList());
  }

  /// Character typed: request suggestions with debounce and only from local catalog.
  void _typed(String text) {
    _typing?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    final ask = widget.onSuggest;
    if (ask == null) {
      return;
    }
    _typing = Timer(
      SearchScreen.typingPause,
      () => unawaited(_suggest(ask, text)),
    );
  }

  Future<void> _suggest(
    Future<List<String>> Function(String) ask,
    String text,
  ) async {
    final request = ++_suggestRequest;
    try {
      final hints = await ask(text);
      // User continued typing while suggestions were fetched: old suggestions under
      // a new word are worse than none.
      if (!mounted || request != _suggestRequest || _field.text != text) {
        return;
      }
      setState(() {
        _suggestions = hints;
        _failure = null;
      });
    } on SearchFailed catch (failed) {
      if (!mounted || request != _suggestRequest || _field.text != text) {
        return;
      }
      setState(() {
        _suggestions = const [];
        _failure = failed.reason;
      });
    }
  }

  void _pick(String query) {
    _field.text = query;
    unawaited(_run(query));
  }

  /// Clear button: reset search. Increment counters so stale responses
  /// do not overwrite the cleared screen.
  void _clear() {
    _typing?.cancel();
    _suggestRequest++;
    _request++;
    _field.clear();
    setState(() {
      _loading = false;
      _searched = false;
      _results = const SearchResult();
      _suggestions = const [];
      _failure = null;
    });
  }

  Future<void> _run(String query) async {
    if (!mounted) {
      return;
    }
    _typing?.cancel();
    // Search initiated: suggestions no longer needed, otherwise they cover results.
    _suggestRequest++;
    final request = ++_request;
    setState(() {
      _loading = true;
      _failure = null;
      _suggestions = const [];
    });
    final recent = widget.recent;
    if (recent != null) {
      unawaited(recent.remember(query).then(_showRecent));
    }
    var results = const SearchResult();
    SearchFailure? failure;
    try {
      results = await widget.onSearch(query);
    } on SearchFailed catch (failed) {
      failure = failed.reason;
    } catch (_) {
      failure = SearchFailure.noAnswer;
    }
    // Response arrived after a newer request: ignore it,
    // otherwise slow older search overwrites newer results.
    if (!mounted || request != _request) {
      return;
    }
    setState(() {
      _loading = false;
      _searched = true;
      _results = results;
      _failure = failure;
    });
    if (results.tracks.isNotEmpty) {
      widget.onResults?.call(results.tracks);
    }
    _hearts?.show(results.tracks).ignore();
  }

  List<Widget> _idle(BuildContext context) {
    final text = l10n(context);
    return [
      if (_recent.isNotEmpty) ...[
        Row(
          children: [
            Expanded(child: Heading(text.searchRecent)),
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 16),
              child: TextButton(
                key: const Key('recent-clear'),
                style: TextButton.styleFrom(
                  foregroundColor: ApertonoColors.textSecondary,
                ),
                onPressed: () {
                  widget.recent?.clear();
                  setState(() => _recent = const []);
                },
                child: Text(text.searchClear),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: SizedBox(
            height: 19 + MediaQuery.textScalerOf(context).scale(13),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final query in _recent)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      key: Key('recent-$query'),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: ApertonoColors.surface,
                      side: const BorderSide(color: ApertonoColors.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          ApertonoRadii.medium,
                        ),
                      ),
                      labelStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: ApertonoColors.textSecondary,
                      ),
                      label: Text(query),
                      onPressed: () => _pick(query),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      if (_heardTracks.isNotEmpty) ...[
        Heading(text.searchHeard),
        _tracksTile('heard-tracks', [
          for (final (index, track) in _heardTracks.indexed)
            TrackTile(
              key: Key('heard-track-${track.id}'),
              track: track,
              services: widget.services,
              hearts: _hearts,
              oneTap: true,
              // Entire list starting from tapped track, like search results: single track
              // lacked "next" in player sheet.
              onTap: () {
                final (queue, start) = queueFrom(_heardTracks, index);
                widget.onSelect(queue, start);
              },
            ),
        ]),
      ],
    ];
  }

  List<Widget> _resultsRows(BuildContext context) {
    final text = l10n(context);
    final seen = <String>{};
    final artists = [
      for (final name in _results.artists)
        if (seen.add(name)) name,
    ];
    final tracks = _results.tracks;
    return [
      for (final name in artists.take(3))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Container(
            key: Key('artist-$name'),
            decoration: BoxDecoration(
              color: ApertonoColors.surface,
              borderRadius: BorderRadius.circular(ApertonoRadii.row),
              border: Border.all(color: ApertonoColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: switch (widget.onArtist) {
                  final open? => () => open(name),
                  null => null,
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      ArtistAvatar(
                        name: name,
                        photo: _results.photos[name],
                        server: widget.services?.server,
                        size: 54,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              text.searchArtistLabel,
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: ApertonoColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right,
                        color: ApertonoColors.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      if (tracks.isNotEmpty) ...[
        Heading(text.searchTracks),
        _tracksTile('search-tracks', [
          for (var index = 0; index < tracks.length; index++)
            TrackTile(
              track: tracks[index],
              services: widget.services,
              hearts: _hearts,
              oneTap: true,
              onTap: () => widget.onSelect(tracks, index),
            ),
        ]),
      ],
    ];
  }

  Widget _tracksTile(String key, List<Widget> tracks) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        key: Key(key),
        decoration: BoxDecoration(
          color: ApertonoColors.surface,
          borderRadius: BorderRadius.circular(ApertonoRadii.xLarge),
          border: Border.all(color: ApertonoColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              for (final (index, track) in tracks.indexed) ...[
                if (index > 0)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: ApertonoColors.border,
                  ),
                track,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// List under search bar: suggestions while typing, recent queries on empty
  /// query, otherwise search results. All three share the space right
  /// beneath the input field.
  List<Widget> _rows(BuildContext context) {
    if (_suggestions.isNotEmpty) {
      return [
        for (final hint in _suggestions)
          ListTile(
            key: Key('suggestion-$hint'),
            leading: const Icon(Icons.search),
            title: Text(hint),
            onTap: () => _pick(hint),
          ),
      ];
    }
    if (!_searched && _field.text.isEmpty) {
      return _idle(context);
    }
    return _resultsRows(context);
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    final text = l10n(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  if (Navigator.of(context).canPop())
                    const BackButton(key: Key('search-back')),
                  Expanded(
                    child: Text(
                      text.searchTitle,
                      key: const Key('search-title'),
                      style: ApertonoText.screenTitle,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _field,
                builder: (context, value, _) {
                  return TextField(
                    key: const Key('search-field'),
                    controller: _field,
                    focusNode: _focus,
                    style: const TextStyle(
                      fontFamily: ApertonoFonts.sans,
                      fontSize: 16,
                      color: ApertonoColors.textPrimary,
                    ),
                    cursorColor: ApertonoColors.accent,
                    decoration: InputDecoration(
                      constraints: const BoxConstraints.tightFor(height: 50),
                      hintText: text.searchHint,
                      filled: true,
                      fillColor: ApertonoColors.surface,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          ApertonoRadii.medium,
                        ),
                        borderSide: const BorderSide(
                          color: ApertonoColors.border,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          ApertonoRadii.medium,
                        ),
                        borderSide: const BorderSide(
                          color: ApertonoColors.accent,
                          width: 2,
                        ),
                      ),
                      prefixIcon: const Icon(Icons.search, size: 20),
                      prefixIconColor: ApertonoColors.textSecondary,
                      suffixIconColor: ApertonoColors.textSecondary,
                      suffixIcon: value.text.isEmpty
                          ? null
                          : IconButton(
                              key: const Key('search-clear'),
                              icon: const Icon(Icons.clear),
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              tooltip: text.searchClear,
                              onPressed: _clear,
                            ),
                    ),
                    textInputAction: TextInputAction.search,
                    onChanged: _typed,
                    onSubmitted: _run,
                  );
                },
              ),
            ),
            if (_loading)
              const LinearProgressIndicator(key: Key('search-loading')),
            if (failure != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  searchFailureText(failure, text),
                  key: const Key('search-error'),
                ),
              )
            else if (_searched && !_loading && _results.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(text.searchEmpty, key: const Key('search-empty')),
              ),
            Expanded(
              child: ListView(controller: _scroll, children: _rows(context)),
            ),
          ],
        ),
      ),
    );
  }
}
