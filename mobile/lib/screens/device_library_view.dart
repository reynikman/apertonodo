import 'package:flutter/material.dart';
import 'package:music_stream/device_library.dart';
import 'package:music_stream/l10n/l10n.dart';

enum DeviceTab { songs, albums, artists, folders }

class _Group {
  final String title;
  final List<DeviceSong> songs;

  const _Group({required this.title, required this.songs});
}

class DeviceLibraryView extends StatefulWidget {
  final DeviceLibrary library;
  final void Function(List<DeviceSong> queue, int index) onPlay;
  final VoidCallback onOpenSettings;

  const DeviceLibraryView({
    super.key,
    required this.library,
    required this.onPlay,
    required this.onOpenSettings,
  });

  @override
  State<DeviceLibraryView> createState() => _DeviceLibraryViewState();
}

class _DeviceLibraryViewState extends State<DeviceLibraryView> {
  DeviceTab _currentTab = DeviceTab.songs;
  _Group? _openedGroup;
  List<DeviceSong>? _lastSongs;

  @override
  void initState() {
    super.initState();
    _lastSongs = widget.library.songs;
    widget.library.addListener(_onLibraryChanged);
  }

  @override
  void didUpdateWidget(DeviceLibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_onLibraryChanged);
      widget.library.addListener(_onLibraryChanged);
      if (!identical(_lastSongs, widget.library.songs)) {
        _lastSongs = widget.library.songs;
        _openedGroup = null;
      }
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLibraryChanged);
    super.dispose();
  }

  void _onLibraryChanged() {
    if (!identical(_lastSongs, widget.library.songs)) {
      _lastSongs = widget.library.songs;
      _openedGroup = null;
    }
    setState(() {});
  }

  Widget _buildEmptyState(AppLocalizations strings) {
    final state = widget.library.state;
    if (state == DeviceLibraryState.idle ||
        state == DeviceLibraryState.loading) {
      return const Center(
        child: CircularProgressIndicator(key: Key('device-loading')),
      );
    }

    final String message;
    final Widget button;

    switch (state) {
      case DeviceLibraryState.noAccess:
        message = strings.deviceNoAccess;
        button = FilledButton(
          key: const Key('device-allow'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: widget.library.ask,
          child: Text(strings.deviceAllow),
        );
      case DeviceLibraryState.deniedForever:
        message = strings.deviceDeniedForever;
        button = FilledButton(
          key: const Key('device-settings'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: widget.onOpenSettings,
          child: Text(strings.deviceOpenSettings),
        );
      case DeviceLibraryState.failed:
        message = strings.deviceFailed;
        button = FilledButton(
          key: const Key('device-refresh'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: widget.library.refresh,
          child: Text(strings.deviceRefresh),
        );
      case DeviceLibraryState.empty:
      case DeviceLibraryState.ready:
      case DeviceLibraryState.idle:
      case DeviceLibraryState.loading:
        message = strings.deviceEmpty;
        button = FilledButton(
          key: const Key('device-refresh'),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: widget.library.refresh,
          child: Text(strings.deviceRefresh),
        );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              key: const Key('device-message'),
              liveRegion: true,
              child: Text(message, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            button,
          ],
        ),
      ),
    );
  }

  Widget _buildSongTile({
    required DeviceSong song,
    required int index,
    required VoidCallback onTap,
    required AppLocalizations strings,
  }) {
    final titleText = song.title.isNotEmpty
        ? song.title
        : strings.deviceUntitled;
    final String? subtitleText;
    if (song.artist.isNotEmpty && song.album.isNotEmpty) {
      subtitleText = '${song.artist} · ${song.album}';
    } else if (song.artist.isNotEmpty) {
      subtitleText = song.artist;
    } else if (song.album.isNotEmpty) {
      subtitleText = song.album;
    } else {
      subtitleText = null;
    }

    return ListTile(
      key: Key('device-row-$index'),
      minTileHeight: 48,
      title: Text(titleText, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitleText != null
          ? Text(subtitleText, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: onTap,
    );
  }

  Widget _buildListArea(AppLocalizations strings) {
    if (_openedGroup != null) {
      final songs = _openedGroup!.songs;
      // Opened group always starts from beginning: separate scroll position for each.
      return KeyedSubtree(
        key: ObjectKey(_openedGroup),
        child: _groupSongs(songs, strings),
      );
    }

    // Each tab has its own scroll position preserved on "back": otherwise a short album list
    // opens scrolled to the end if songs were scrolled far down.
    return KeyedSubtree(
      key: PageStorageKey<String>('device-${_currentTab.name}'),
      child: _buildTab(strings),
    );
  }

  Widget _groupSongs(List<DeviceSong> songs, AppLocalizations strings) {
    return ListView.builder(
      key: const Key('device-list'),
      itemCount: songs.length,
      itemBuilder: (context, index) => _buildSongTile(
        song: songs[index],
        index: index,
        onTap: () => widget.onPlay(songs, index),
        strings: strings,
      ),
    );
  }

  Widget _buildTab(AppLocalizations strings) {
    switch (_currentTab) {
      case DeviceTab.songs:
        final songs = widget.library.songs;
        return ListView.builder(
          key: const Key('device-list'),
          itemCount: songs.length,
          itemBuilder: (context, index) {
            final song = songs[index];
            return _buildSongTile(
              song: song,
              index: index,
              onTap: () => widget.onPlay(songs, index),
              strings: strings,
            );
          },
        );

      case DeviceTab.albums:
        final albums = widget.library.albums;
        if (albums.isEmpty) {
          return Center(
            child: Text(
              strings.deviceTabEmpty,
              key: const Key('device-tab-empty'),
            ),
          );
        }
        return ListView.builder(
          key: const Key('device-list'),
          itemCount: albums.length,
          itemBuilder: (context, index) {
            final album = albums[index];
            final countStr = strings.deviceSongCount(album.songs.length);
            final subtitleText = album.artist.isNotEmpty
                ? '${album.artist} · $countStr'
                : countStr;
            return ListTile(
              key: Key('device-row-$index'),
              minTileHeight: 48,
              title: Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                subtitleText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                setState(() {
                  _openedGroup = _Group(title: album.name, songs: album.songs);
                });
              },
            );
          },
        );

      case DeviceTab.artists:
        final artists = widget.library.artists;
        if (artists.isEmpty) {
          return Center(
            child: Text(
              strings.deviceTabEmpty,
              key: const Key('device-tab-empty'),
            ),
          );
        }
        return ListView.builder(
          key: const Key('device-list'),
          itemCount: artists.length,
          itemBuilder: (context, index) {
            final artist = artists[index];
            final subtitleText = strings.deviceSongCount(artist.songs.length);
            return ListTile(
              key: Key('device-row-$index'),
              minTileHeight: 48,
              title: Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                subtitleText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                setState(() {
                  _openedGroup = _Group(
                    title: artist.name,
                    songs: artist.songs,
                  );
                });
              },
            );
          },
        );

      case DeviceTab.folders:
        final folders = widget.library.folders;
        if (folders.isEmpty) {
          return Center(
            child: Text(
              strings.deviceTabEmpty,
              key: const Key('device-tab-empty'),
            ),
          );
        }
        return ListView.builder(
          key: const Key('device-list'),
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final folder = folders[index];
            return ListTile(
              key: Key('device-row-$index'),
              minTileHeight: 48,
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                folder.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                setState(() {
                  _openedGroup = _Group(
                    title: folder.name,
                    songs: folder.songs,
                  );
                });
              },
            );
          },
        );
    }
  }

  Widget _buildTabChip({
    required Key key,
    required String label,
    required DeviceTab tab,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        key: key,
        label: Text(label),
        selected: _currentTab == tab,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onSelected: (_) {
          setState(() {
            _currentTab = tab;
            _openedGroup = null;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = l10n(context);

    if (widget.library.songs.isEmpty) {
      return _buildEmptyState(strings);
    }

    final isLoading = widget.library.state == DeviceLibraryState.loading;
    final isFailed = widget.library.state == DeviceLibraryState.failed;

    return PopScope(
      canPop: _openedGroup == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _openedGroup != null) {
          setState(() {
            _openedGroup = null;
          });
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildTabChip(
                        key: const Key('device-tab-songs'),
                        label: strings.deviceTabSongs,
                        tab: DeviceTab.songs,
                      ),
                      _buildTabChip(
                        key: const Key('device-tab-albums'),
                        label: strings.deviceTabAlbums,
                        tab: DeviceTab.albums,
                      ),
                      _buildTabChip(
                        key: const Key('device-tab-artists'),
                        label: strings.deviceTabArtists,
                        tab: DeviceTab.artists,
                      ),
                      _buildTabChip(
                        key: const Key('device-tab-folders'),
                        label: strings.deviceTabFolders,
                        tab: DeviceTab.folders,
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const Key('device-refresh'),
                tooltip: strings.deviceRefresh,
                onPressed: isLoading ? null : widget.library.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (isLoading)
            const LinearProgressIndicator(key: Key('device-refreshing')),
          if (isFailed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Semantics(
                key: const Key('device-message'),
                liveRegion: true,
                child: Text(strings.deviceRefreshFailed),
              ),
            ),
          if (_openedGroup != null)
            Row(
              children: [
                IconButton(
                  key: const Key('device-back'),
                  tooltip: strings.deviceBack,
                  onPressed: () {
                    setState(() {
                      _openedGroup = null;
                    });
                  },
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    _openedGroup!.title,
                    key: const Key('device-group-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          Expanded(child: _buildListArea(strings)),
        ],
      ),
    );
  }
}
