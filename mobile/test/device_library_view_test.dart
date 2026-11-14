import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/device_library.dart';
import 'package:music_stream/l10n/l10n.dart';
import 'package:music_stream/screens/device_library_view.dart';

/// Lead check FT-653: "On device" screen — screen body over FT-652 model.

const _music = '/storage/emulated/0/Music';

class _Port implements DeviceMediaPort {
  _Port({
    this.now = DeviceAccess.granted,
    DeviceAccess? asked,
    List<DeviceSong>? list,
  }) : asked = asked ?? now,
       list = list ?? const [];
  DeviceAccess now;
  DeviceAccess asked;
  List<DeviceSong> list;
  Object? songsError;
  Completer<List<DeviceSong>>? hold;
  final calls = <String>[];

  @override
  Future<DeviceAccess> access() async {
    calls.add('access');
    return now;
  }

  @override
  Future<DeviceAccess> request() async {
    calls.add('request');
    return now = asked;
  }

  @override
  Future<List<DeviceSong>> songs() {
    calls.add('songs');
    if (songsError != null) return Future.error(songsError!);
    return hold?.future ?? Future.value(list);
  }
}

DeviceSong _song(
  String uri, {
  String? title,
  String artist = '',
  String album = '',
  int? track,
  String? path,
}) => DeviceSong(
  uri: uri,
  title: title ?? uri,
  artist: artist,
  album: album,
  durationMs: 200000,
  track: track,
  path: path ?? '$_music/$uri.mp3',
);

/// Small library: two albums (one compilation), three artists, two folders.
final _shelf = [
  _song('a1', title: 'Вечер', artist: 'Анна', album: 'Город', track: 2),
  _song('a2', title: 'Утро', artist: 'Анна', album: 'Город', track: 1),
  _song(
    'b1',
    title: 'Берег',
    artist: 'Борис',
    album: 'Сборник лета',
    path: '$_music/Лето/b1.mp3',
  ),
  _song(
    'c1',
    title: 'Ветер',
    artist: 'Вера',
    album: 'Сборник лета',
    path: '$_music/Лето/c1.mp3',
  ),
  _song('d1', title: 'Дом'),
];

AppLocalizations _text([String code = 'ru']) =>
    lookupAppLocalizations(Locale(code));

Finder _key(String name) => find.byKey(Key(name));

class _Shown {
  _Shown(this.library, this.port);
  final DeviceLibrary library;
  final _Port port;
  final played = <(List<DeviceSong>, int)>[];
  int settings = 0;
}

Future<_Shown> _show(
  WidgetTester tester, {
  _Port? port,
  bool open = true,
  Locale locale = const Locale('ru'),
  double width = 400,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final shown = _Shown(DeviceLibrary(port ??= _Port(list: _shelf)), port);
  addTearDown(shown.library.dispose);
  if (open) await shown.library.open();
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DeviceLibraryView(
          library: shown.library,
          onPlay: (queue, index) => shown.played.add((queue, index)),
          onOpenSettings: () => shown.settings++,
        ),
      ),
    ),
  );
  await tester.pump();
  return shown;
}

/// Title and subtitle of list item at [index].
(String, String?) _row(WidgetTester tester, int index) {
  final texts = tester
      .widgetList<Text>(
        find.descendant(
          of: _key('device-row-$index'),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data)
      .toList();
  return (texts.first!, texts.length > 1 ? texts[1] : null);
}

List<String> _titles(WidgetTester tester) => [
  for (var i = 0; _key('device-row-$i').evaluate().isNotEmpty; i++)
    _row(tester, i).$1,
];

/// Tabs scroll horizontally: on narrow screen last tab may be off-screen.
Future<void> _tab(WidgetTester tester, String name) async {
  await tester.ensureVisible(_key('device-tab-$name'));
  await tester.pump();
  await tester.tap(_key('device-tab-$name'));
  await tester.pump();
}

String _message(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(of: _key('device-message'), matching: find.byType(Text)),
    )
    .data!;

void main() {
  group('while no music', () {
    testWidgets('does not query phone on its own; waits for response', (
      tester,
    ) async {
      final shown = await _show(tester, open: false);
      expect(shown.port.calls, isEmpty);
      expect(_key('device-loading'), findsOneWidget);
      expect(_key('device-message'), findsNothing);
      expect(_key('device-list'), findsNothing);
    });

    testWidgets('reading in progress: waiting, no words', (tester) async {
      final port = _Port()..hold = Completer();
      final shown = await _show(tester, port: port, open: false);
      unawaited(shown.library.open());
      await tester.pump();
      expect(shown.library.state, DeviceLibraryState.loading);
      expect(_key('device-loading'), findsOneWidget);
      expect(_key('device-refresh'), findsNothing);
    });

    testWidgets('no permission: explanation and allow system dialog', (
      tester,
    ) async {
      final shown = await _show(
        tester,
        port: _Port(
          now: DeviceAccess.denied,
          asked: DeviceAccess.granted,
          list: _shelf,
        ),
      );
      expect(_message(tester), _text().deviceNoAccess);
      expect(find.text(_text().deviceAllow), findsOneWidget);
      expect(_key('device-settings'), findsNothing);
      expect(_key('device-refresh'), findsNothing);
      shown.port.calls.clear();

      await tester.tap(_key('device-allow'));
      await tester.pumpAndSettle();
      expect(shown.port.calls, ['request', 'songs']);
      expect(_key('device-message'), findsNothing);
      expect(_titles(tester), ['Берег', 'Ветер', 'Вечер', 'Дом', 'Утро']);
    });

    testWidgets(
      'permanently denied: dialog not shown, leads to phone settings',
      (tester) async {
        final shown = await _show(
          tester,
          port: _Port(now: DeviceAccess.deniedForever),
        );
        expect(_message(tester), _text().deviceDeniedForever);
        expect(_key('device-allow'), findsNothing);
        expect(find.text(_text().deviceOpenSettings), findsOneWidget);
        shown.port.calls.clear();

        await tester.tap(_key('device-settings'));
        await tester.pump();
        expect(shown.settings, 1);
        expect(shown.port.calls, isEmpty);
      },
    );

    testWidgets('no music: stated clearly, can refresh', (tester) async {
      final shown = await _show(tester, port: _Port());
      expect(_message(tester), _text().deviceEmpty);
      expect(_key('device-allow'), findsNothing);
      shown.port.calls.clear();
      shown.port.list = _shelf;

      await tester.tap(_key('device-refresh'));
      await tester.pumpAndSettle();
      expect(shown.port.calls, ['access', 'songs']);
      expect(_titles(tester), hasLength(5));
    });

    testWidgets('read failure: named, retry button retries', (tester) async {
      final port = _Port(list: _shelf)..songsError = StateError('x');
      final shown = await _show(tester, port: port);
      expect(_message(tester), _text().deviceFailed);
      expect(_message(tester), isNot(_text().deviceEmpty));
      port.songsError = null;

      await tester.tap(_key('device-refresh'));
      await tester.pumpAndSettle();
      expect(shown.library.state, DeviceLibraryState.ready);
      expect(_key('device-message'), findsNothing);
    });

    testWidgets('words are read aloud via TalkBack', (tester) async {
      final handle = tester.ensureSemantics();
      await _show(tester, port: _Port(now: DeviceAccess.denied));
      expect(
        tester.getSemantics(_key('device-message')),
        matchesSemantics(label: _text().deviceNoAccess, isLiveRegion: true),
      );
      handle.dispose();
    });
  });

  group('songs', () {
    testWidgets('list in model order; subtitle is artist and album', (
      tester,
    ) async {
      await _show(tester);
      expect(_titles(tester), ['Берег', 'Ветер', 'Вечер', 'Дом', 'Утро']);
      expect(_row(tester, 2), ('Вечер', 'Анна · Город'));
      // Neither artist nor album — no subtitle at all, not empty string or dot.
      expect(_row(tester, 3), ('Дом', null));
      expect(_key('device-loading'), findsNothing);
      expect(_key('device-back'), findsNothing);
    });

    testWidgets('subtitle contains no empty parts', (tester) async {
      await _show(
        tester,
        port: _Port(
          list: [
            _song('1', title: 'А', artist: 'Анна'),
            _song('2', title: 'Б', album: 'Город'),
          ],
        ),
      );
      expect(_row(tester, 0), ('А', 'Анна'));
      expect(_row(tester, 1), ('Б', 'Город'));
    });

    testWidgets('song without title or file displays untitled string', (
      tester,
    ) async {
      await _show(
        tester,
        port: _Port(
          list: [_song('x', title: '', path: '')],
        ),
      );
      expect(_row(tester, 0).$1, _text().deviceUntitled);
    });

    testWidgets('tap: entire list becomes queue with current index', (
      tester,
    ) async {
      final shown = await _show(tester);
      await tester.tap(_key('device-row-2'));
      await tester.pump();
      expect(shown.played, hasLength(1));
      expect(identical(shown.played.single.$1, shown.library.songs), isTrue);
      expect(shown.played.single.$2, 2);
    });

    testWidgets('twenty thousand songs: builds only visible rows list', (
      tester,
    ) async {
      await _show(
        tester,
        port: _Port(
          list: [
            for (var i = 0; i < 20000; i++)
              _song('s$i', title: 'Песня ${i.toString().padLeft(5, '0')}'),
          ],
        ),
      );
      expect(
        find.byType(ListTile, skipOffstage: false).evaluate().length,
        lessThan(60),
      );
      await tester.fling(_key('device-list'), const Offset(0, -3000), 5000);
      await tester.pumpAndSettle();
      expect(_key('device-row-0'), findsNothing);
      expect(
        find.byType(ListTile, skipOffstage: false).evaluate().length,
        lessThan(60),
      );
    });
  });

  group('tabs', () {
    testWidgets('four tabs, songs tab selected', (tester) async {
      await _show(tester);
      final text = _text();
      for (final (name, label) in [
        ('songs', text.deviceTabSongs),
        ('albums', text.deviceTabAlbums),
        ('artists', text.deviceTabArtists),
        ('folders', text.deviceTabFolders),
      ]) {
        expect(
          find.descendant(
            of: _key('device-tab-$name'),
            matching: find.text(label),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<ChoiceChip>(_key('device-tab-$name')).selected,
          name == 'songs',
        );
      }
      await _tab(tester, 'artists');
      expect(
        tester.widget<ChoiceChip>(_key('device-tab-artists')).selected,
        isTrue,
      );
      expect(
        tester.widget<ChoiceChip>(_key('device-tab-songs')).selected,
        isFalse,
      );
    });

    testWidgets(
      'albums: artist and track count; compilation has track count only',
      (tester) async {
        await _show(tester);
        await _tab(tester, 'albums');
        expect(_row(tester, 0), ('Город', 'Анна · 2 песни'));
        expect(_row(tester, 1), ('Сборник лета', '2 песни'));
        expect(_key('device-row-2'), findsNothing);
      },
    );

    testWidgets('album opens: songs by track number, queue is album', (
      tester,
    ) async {
      final shown = await _show(tester);
      await _tab(tester, 'albums');
      await tester.tap(_key('device-row-0'));
      await tester.pump();
      expect(shown.played, isEmpty);
      expect(tester.widget<Text>(_key('device-group-title')).data, 'Город');
      expect(_titles(tester), ['Утро', 'Вечер']);

      await tester.tap(_key('device-row-1'));
      await tester.pump();
      final album = shown.library.albums.first;
      expect(identical(shown.played.single.$1, album.songs), isTrue);
      expect(shown.played.single.$2, 1);
    });

    testWidgets('back button returns to albums list', (tester) async {
      await _show(tester);
      await _tab(tester, 'albums');
      await tester.tap(_key('device-row-1'));
      await tester.pump();
      expect(_titles(tester), ['Берег', 'Ветер']);
      expect(find.byTooltip(_text().deviceBack), findsOneWidget);

      await tester.tap(_key('device-back'));
      await tester.pump();
      expect(_key('device-back'), findsNothing);
      expect(_key('device-group-title'), findsNothing);
      expect(_titles(tester), ['Город', 'Сборник лета']);
    });

    testWidgets('system back: closes album first, screen remains open', (
      tester,
    ) async {
      await _show(tester);
      await _tab(tester, 'albums');
      await tester.tap(_key('device-row-0'));
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_key('device-back'), findsNothing);
      expect(_titles(tester), ['Город', 'Сборник лета']);
      // Album closed — next "back" is not ours: screen does not intercept it.
      final scope = find.descendant(
        of: find.byType(DeviceLibraryView),
        matching: find.byWidgetPredicate((w) => w is PopScope),
      );
      expect(tester.widget<PopScope>(scope).canPop, isTrue);
    });

    testWidgets('artists: song count; tapping shows songs', (tester) async {
      final shown = await _show(tester);
      await _tab(tester, 'artists');
      expect(_row(tester, 0), ('Анна', '2 песни'));
      expect(_row(tester, 1), ('Борис', '1 песня'));
      expect(_titles(tester), ['Анна', 'Борис', 'Вера']);

      await tester.tap(_key('device-row-0'));
      await tester.pump();
      expect(tester.widget<Text>(_key('device-group-title')).data, 'Анна');
      expect(_titles(tester), ['Вечер', 'Утро']);
      await tester.tap(_key('device-row-0'));
      expect(
        identical(shown.played.single.$1, shown.library.artists.first.songs),
        isTrue,
      );
    });

    testWidgets('folders: name and path; inside are songs', (tester) async {
      await _show(tester);
      await _tab(tester, 'folders');
      expect(_row(tester, 0), ('Music', _music));
      expect(_row(tester, 1), ('Лето', '$_music/Лето'));
      await tester.tap(_key('device-row-1'));
      await tester.pump();
      expect(_titles(tester), ['Берег', 'Ветер']);
    });

    testWidgets(
      'tab has independent scroll: after song list albums start at top',
      (tester) async {
        await _show(
          tester,
          port: _Port(
            list: [
              for (var i = 0; i < 300; i++)
                _song(
                  's$i',
                  title: 'Песня ${i.toString().padLeft(3, '0')}',
                  artist: 'Анна',
                  album: 'Альбом ${(i ~/ 10).toString().padLeft(2, '0')}',
                ),
            ],
          ),
        );
        await tester.fling(_key('device-list'), const Offset(0, -3000), 8000);
        await tester.pumpAndSettle();
        expect(_key('device-row-0'), findsNothing);

        await _tab(tester, 'albums');
        expect(_row(tester, 0).$1, 'Альбом 00');
        await tester.drag(_key('device-list'), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(_key('device-row-0'), findsNothing);
        final seen = _key('device-row-12');
        expect(seen, findsOneWidget);
        final where = tester.getTopLeft(seen).dy;

        // Album opens from top, while "back" restores same scroll offset in album list.
        await tester.tap(seen);
        await tester.pump();
        expect(_row(tester, 0).$1, 'Песня 120');
        await tester.tap(_key('device-back'));
        await tester.pump();
        expect(tester.getTopLeft(_key('device-row-12')).dy, where);

        // And songs remained scrolled to where they were.
        await _tab(tester, 'songs');
        expect(_key('device-row-0'), findsNothing);
      },
    );

    testWidgets('switching tab closes open album view', (tester) async {
      await _show(tester);
      await _tab(tester, 'albums');
      await tester.tap(_key('device-row-0'));
      await tester.pump();
      await _tab(tester, 'songs');
      expect(_key('device-back'), findsNothing);
      expect(_titles(tester), hasLength(5));

      await _tab(tester, 'albums');
      expect(_key('device-back'), findsNothing);
      expect(_titles(tester), ['Город', 'Сборник лета']);
    });

    testWidgets('empty tab states it clearly, tabs remain in place', (
      tester,
    ) async {
      await _show(
        tester,
        port: _Port(list: [_song('d1', title: 'Дом')]),
      );
      await _tab(tester, 'albums');
      expect(
        tester.widget<Text>(_key('device-tab-empty')).data,
        _text().deviceTabEmpty,
      );
      expect(_key('device-list'), findsNothing);
      expect(_key('device-tab-songs'), findsOneWidget);
    });
  });

  group('refresh', () {
    testWidgets('refresh button updates; while in flight button disabled', (
      tester,
    ) async {
      final shown = await _show(tester);
      expect(find.byTooltip(_text().deviceRefresh), findsOneWidget);
      expect(_key('device-refreshing'), findsNothing);
      shown.port
        ..calls.clear()
        ..hold = Completer();

      await tester.tap(_key('device-refresh'));
      await tester.pump();
      expect(shown.port.calls, ['access', 'songs']);
      expect(_key('device-refreshing'), findsOneWidget);
      expect(_key('device-loading'), findsNothing);
      expect(_titles(tester), hasLength(5));
      expect(
        tester.widget<IconButton>(_key('device-refresh')).onPressed,
        isNull,
      );

      shown.port.hold!.complete([_song('n1', title: 'Новая')]);
      await tester.pumpAndSettle();
      expect(_key('device-refreshing'), findsNothing);
      expect(_titles(tester), ['Новая']);
      expect(
        tester.widget<IconButton>(_key('device-refresh')).onPressed,
        isNotNull,
      );
    });

    testWidgets('refresh failure: list stays, error announced aloud', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final shown = await _show(tester);
      shown.port.songsError = StateError('x');
      await tester.tap(_key('device-refresh'));
      await tester.pumpAndSettle();
      expect(shown.library.state, DeviceLibraryState.failed);
      expect(_titles(tester), hasLength(5));
      expect(
        tester.getSemantics(_key('device-message')),
        matchesSemantics(
          label: _text().deviceRefreshFailed,
          isLiveRegion: true,
        ),
      );
      expect(_key('device-refresh'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('list refreshed: currently open album is closed', (
      tester,
    ) async {
      final shown = await _show(tester);
      await _tab(tester, 'albums');
      await tester.tap(_key('device-row-0'));
      await tester.pump();
      shown.port.list = [
        _song('z1', title: 'Заря', artist: 'Зоя', album: 'Звук'),
      ];

      await tester.tap(_key('device-refresh'));
      await tester.pumpAndSettle();
      expect(_key('device-back'), findsNothing);
      expect(find.text('Утро'), findsNothing);
      expect(_titles(tester), ['Звук']);
    });

    testWidgets('refresh failure leaves open album intact', (tester) async {
      final shown = await _show(tester);
      await _tab(tester, 'albums');
      await tester.tap(_key('device-row-0'));
      await tester.pump();
      shown.port.songsError = StateError('x');
      await tester.tap(_key('device-refresh'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(_key('device-group-title')).data, 'Город');
      expect(_titles(tester), ['Утро', 'Вечер']);
    });

    testWidgets('permission revoked: list cleared, prompt requested', (
      tester,
    ) async {
      final shown = await _show(tester);
      shown.port.now = DeviceAccess.denied;
      await tester.tap(_key('device-refresh'));
      await tester.pumpAndSettle();
      expect(_message(tester), _text().deviceNoAccess);
      expect(_key('device-list'), findsNothing);
      expect(_key('device-tab-songs'), findsNothing);
      expect(_key('device-allow'), findsOneWidget);
    });
  });

  group('view', () {
    testWidgets('rows, tabs and buttons at least 48 dp high', (tester) async {
      await _show(tester);
      await _tab(tester, 'albums');
      await tester.tap(_key('device-row-0'));
      await tester.pump();
      for (final name in [
        'device-row-0',
        'device-tab-songs',
        'device-tab-folders',
        'device-refresh',
        'device-back',
      ]) {
        expect(
          tester.getSize(_key(name)).height,
          greaterThanOrEqualTo(48),
          reason: name,
        );
      }
      await tester.pumpWidget(const SizedBox());
      await _show(tester, port: _Port(now: DeviceAccess.denied));
      expect(
        tester.getSize(_key('device-allow')).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets(
      'row without subtitle also at least 48 dp; long text ellipses',
      (tester) async {
        await _show(tester);
        expect(_row(tester, 3), ('Дом', null));
        expect(
          tester.getSize(_key('device-row-3')).height,
          greaterThanOrEqualTo(48),
        );
        for (final line in tester.widgetList<Text>(
          find.descendant(
            of: _key('device-row-2'),
            matching: find.byType(Text),
          ),
        )) {
          expect(line.maxLines, 1);
          expect(line.overflow, TextOverflow.ellipsis);
        }
      },
    );

    testWidgets('untitled rendered in user language', (tester) async {
      await _show(
        tester,
        port: _Port(
          list: [_song('x', title: '', path: '')],
        ),
        locale: const Locale('en'),
      );
      expect(_row(tester, 0).$1, _text('en').deviceUntitled);
    });

    testWidgets('song count pluralizes correctly', (tester) async {
      final ru = _text(), en = _text('en');
      expect(ru.deviceSongCount(1), '1 песня');
      expect(ru.deviceSongCount(3), '3 песни');
      expect(ru.deviceSongCount(5), '5 песен');
      expect(ru.deviceSongCount(11), '11 песен');
      expect(ru.deviceSongCount(21), '21 песня');
      expect(en.deviceSongCount(1), '1 song');
      expect(en.deviceSongCount(2), '2 songs');
    });

    testWidgets('English: same slots, English vocabulary', (tester) async {
      final en = _text('en');
      await _show(tester, locale: const Locale('en'));
      expect(find.text(en.deviceTabSongs), findsOneWidget);
      expect(find.text(en.deviceTabFolders), findsOneWidget);
      expect(find.byTooltip(en.deviceRefresh), findsOneWidget);
      await _tab(tester, 'albums');
      expect(_row(tester, 0), ('Город', 'Анна · 2 songs'));
      await tester.pumpWidget(const SizedBox());
      await _show(
        tester,
        port: _Port(now: DeviceAccess.deniedForever),
        locale: const Locale('en'),
      );
      expect(_message(tester), en.deviceDeniedForever);
      expect(find.text(en.deviceOpenSettings), findsOneWidget);
    });

    for (final code in ['ru', 'en']) {
      testWidgets('320 dp, $code: nothing overflows', (tester) async {
        final long = 'Очень длинное название, которое не помещается ' * 4;
        final wide = [
          _song(
            'w1',
            title: long,
            artist: long,
            album: long,
            path: '$_music/$long/w1.mp3',
          ),
        ];
        for (final access in DeviceAccess.values) {
          await _show(
            tester,
            port: _Port(now: access, list: wide),
            locale: Locale(code),
            width: 320,
          );
          expect(tester.takeException(), isNull, reason: '$access');
          if (access == DeviceAccess.granted) {
            for (final tab in ['albums', 'artists', 'folders']) {
              await _tab(tester, tab);
              expect(tester.takeException(), isNull, reason: tab);
              await tester.tap(_key('device-row-0'));
              await tester.pump();
              expect(tester.takeException(), isNull, reason: '$tab inside');
            }
          }
          await tester.pumpWidget(const SizedBox());
        }
        await _show(tester, port: _Port(), locale: Locale(code), width: 320);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('rows', () {
    test('every key has both locales, and they differ', () {
      final ru = _text(), en = _text('en');
      final pairs = {
        ru.deviceTabSongs: en.deviceTabSongs,
        ru.deviceTabAlbums: en.deviceTabAlbums,
        ru.deviceTabArtists: en.deviceTabArtists,
        ru.deviceTabFolders: en.deviceTabFolders,
        ru.deviceNoAccess: en.deviceNoAccess,
        ru.deviceAllow: en.deviceAllow,
        ru.deviceDeniedForever: en.deviceDeniedForever,
        ru.deviceOpenSettings: en.deviceOpenSettings,
        ru.deviceEmpty: en.deviceEmpty,
        ru.deviceFailed: en.deviceFailed,
        ru.deviceRefresh: en.deviceRefresh,
        ru.deviceRefreshFailed: en.deviceRefreshFailed,
        ru.deviceUntitled: en.deviceUntitled,
        ru.deviceBack: en.deviceBack,
        ru.deviceTabEmpty: en.deviceTabEmpty,
      };
      expect(pairs, hasLength(15));
      for (final entry in pairs.entries) {
        expect(entry.key, isNotEmpty);
        expect(entry.value, isNotEmpty);
        expect(entry.key, isNot(entry.value));
        expect(entry.key, matches(RegExp('[а-яё]')));
        expect(entry.value, isNot(matches(RegExp('[а-яё]'))));
      }
    });
  });
}
