import 'dart:convert';
import 'dart:io';

/// Негативный контроль экранов Фазы I (гейт I13).
///
///   cd mobile && dart run tool/negative_control.dart
///
/// Каждая поломка — то, что владелец запретил: бледная песня пропала, пауза
/// считается прослушиванием, 503 показан как «пусто», запрос ушёл без ключа.
/// Скрипт вносит её в код, требует, чтобы покраснел тест, который это
/// сторожит, и откатывает. В конце весь набор обязан быть зелёным.
///
/// Красный засчитывается, только если упал именно названный тест. Ошибка
/// компиляции роняет «loading …», а не его, и за красный не сходит.
typedef Mutation = ({
  String what,
  String file,
  String find,
  String replace,
  String test,
  String name,
});

// The source-related Russian word is assembled at run time so that it is not in
// the text of this file (the core has no source words outside tests).
final _stem = String.fromCharCodes(const [
  0x440,
  0x430,
  0x437,
  0x434,
  0x430,
  0x447,
]);
final _capStem = String.fromCharCodes(const [
  0x420,
  0x430,
  0x437,
  0x434,
  0x430,
  0x447,
]);

final mutations = <Mutation>[
  (
    what: 'меню открывается не с поиска',
    file: 'lib/screens/menu_screen.dart',
    find: '  var _current = 0;',
    replace: '  var _current = 1;',
    test: 'test/menu_test.dart',
    name: 'home opened first, four-item menu, no network requests',
  ),
  (
    what: 'все вкладки строятся и ходят в сеть при запуске',
    file: 'lib/screens/menu_screen.dart',
    find: 'state.opened.contains(i) ? tabs[i] : const SizedBox.shrink(),',
    replace: 'tabs[i],',
    test: 'test/menu_test.dart',
    name: 'home opened first, four-item menu, no network requests',
  ),
  (
    what: 'светлая тема системы делает приложение светлым',
    file: 'lib/app.dart',
    find:
        '      theme: apertonoTheme(),\n'
        '      darkTheme: apertonoTheme(),\n'
        '      themeMode: ThemeMode.dark,',
    replace:
        '      theme: ThemeData.light(),\n'
        '      darkTheme: apertonoTheme(),\n'
        '      themeMode: ThemeMode.system,',
    test: 'test/menu_test.dart',
    name: 'theme light system — still dark',
  ),
  (
    what: 'неиграющая песня не бледнеет',
    file: 'lib/screens/parts.dart',
    find: '    final pale = track.playable ? null : paleColor(context);',
    replace: '    const Color? pale = null;',
    test: 'test/browse_screens_test.dart',
    name: 'rules unplayable album song — dimmed but in place',
  ),
  (
    what: 'неиграющие песни пропадают из альбома',
    file: 'lib/screens/catalog_screens.dart',
    find:
        '            tracks: tracks,\n            numbered: true,\n            header: [\n              ListTile(\n                leading: Cover(',
    replace:
        '            tracks: [for (final t in tracks) if (t.playable) t],\n            numbered: true,\n            header: [\n              ListTile(\n                leading: Cover(',
    test: 'test/browse_screens_test.dart',
    name: 'rules unplayable album song — dimmed but in place',
  ),
  (
    what: 'неиграющий альбом не бледнеет',
    file: 'lib/screens/catalog_screens.dart',
    find: '    final pale = album.playable ? null : paleColor(context);',
    replace: '    const Color? pale = null;',
    test: 'test/browse_screens_test.dart',
    name: 'rules unplayable album — dimmed but in place',
  ),
  (
    what: 'без обложки нет квадрата с буквами',
    file: 'lib/screens/parts.dart',
    find: '      image = square;',
    replace: '      image = const SizedBox.shrink();',
    test: 'test/browse_screens_test.dart',
    name:
        'rules cover from own server with session token; absent: letter square box',
  ),
  (
    what: 'обложка просится без ключа',
    file: 'lib/screens/parts.dart',
    find: '      headers: server.headers,',
    replace: '      headers: null,',
    test: 'test/browse_screens_test.dart',
    name: 'rules cover image request carries the session token',
  ),
  (
    what: 'блока Last.fm нет в ответе, а заголовок рисуется',
    file: 'lib/screens/catalog_screens.dart',
    find: '            if (page.topTracks.isNotEmpty) ...[',
    replace: '            if (true) ...[',
    test: 'test/browse_screens_test.dart',
    name: 'rules no blocks in the response — none on screen, no placeholders',
  ),
  (
    what: '«Похожие исполнители» из ответа не показаны',
    file: 'lib/screens/catalog_screens.dart',
    find: '            if (page.similar.isNotEmpty) ...[',
    replace: '            if (page.similar.isEmpty) ...[',
    test: 'test/browse_screens_test.dart',
    name: 'rules Last.fm blocks in the response — on screen',
  ),
  (
    what: 'поиск с песни из топа не готовит первую песню',
    file: 'lib/screens/catalog_screens.dart',
    find: '      onResults: (tracks) => services.prepare(tracks.first),\n',
    replace: '',
    test: 'test/browse_screens_test.dart',
    name: 'rules top song without a number — search',
  ),
  (
    what: 'песня топа с номером открывает поиск вместо игры',
    file: 'lib/screens/catalog_screens.dart',
    find:
        '        final (queue, start) = queueFrom(tracks, index < 0 ? 0 : index);\n'
        '        services.play(queue, start);',
    replace:
        '        final (queue, start) = queueFrom(tracks, index < 0 ? 0 : index);\n'
        r"        openSearch(context, services, query: '$artist ${top.title}');",
    test: 'test/browse_screens_test.dart',
    name: 'rules tapped a top song — it plays, search never opened',
  ),
  (
    what: 'поиск меню не готовит первую песню (строка Фазы D после слияния)',
    file: 'lib/app.dart',
    find: '      onResults: (tracks) => _player.prepare(tracks.first),\n',
    replace: '',
    test: 'test/player_queue_test.dart',
    name: 'the first result song is prepared while the person reads',
  ),
  (
    what: 'неиграющая песня встаёт в очередь',
    file: 'lib/screens/parts.dart',
    find: '    if (tracks[i].playable || i == index) {',
    replace: '    if (true) {',
    test: 'test/browse_screens_test.dart',
    name:
        'queue "Play album" — queue G starting at the first playable, dimmed ones skipped',
  ),
  (
    what: '«Играть альбом» не доходит до очереди G',
    file: 'lib/app.dart',
    find:
        '  void _play(List<Track> tracks, int index) =>\n'
        '      unawaited(_player.playQueue(tracks, start: index));',
    replace: '  void _play(List<Track> tracks, int index) {}',
    test: 'test/browse_screens_test.dart',
    name:
        'queue "Play album" — queue G starting at the first playable, dimmed ones skipped',
  ),
  (
    what: 'сердечко не слушает ответ сервера',
    file: 'lib/screens/parts.dart',
    find: '      _liked = liked;',
    replace: '      _liked = <String>{};',
    test: 'test/library_screens_test.dart',
    name: 'heart by the server response: the same song with another id is lit',
  ),
  (
    what: 'поиск не спрашивает сервер про сердечки',
    file: 'lib/screens/search_screen.dart',
    find: '    _hearts?.show(results.tracks).ignore();\n',
    replace: '',
    test: 'test/library_screens_test.dart',
    name: 'heart tapped an empty heart in search — added to favorites and lit',
  ),
  (
    what: 'погасить сердечко нельзя',
    file: 'lib/screens/parts.dart',
    find: '      await server.unlike(track.id);',
    replace: '      await server.like(track.id);',
    test: 'test/library_screens_test.dart',
    name: 'My music heart switched off in favorites — the song leaves the list',
  ),
  (
    what: 'новый порядок уходит не целым списком',
    file: 'lib/screens/parts.dart',
    find: '        onReorder([for (final track in tracks) track.id]);',
    replace: '        onReorder([tracks[to].id]);',
    test: 'test/library_screens_test.dart',
    name: 'playlists reorder — POST with the whole id list',
  ),
  (
    what: 'переименование ушло методом, который NPM не пропустит',
    file: 'lib/server_api.dart',
    find:
        r"      _changeLibrary('/v1/playlists/$id/rename', body: {'name': name});",
    replace:
        r"      _call('PATCH', '/v1/playlists/$id', body: {'name': name});",
    test: 'test/screen_contracts_test.dart',
    name: 'the app sends only GET and POST — NPM cuts the rest',
  ),
  (
    what: 'история не уходит на сервер',
    file: 'lib/player.dart',
    find:
        '    listened(\n'
        '      track.id,\n'
        '      _heard.inMilliseconds,\n'
        '      artworkUrl: track.artworkUrl,\n'
        '    ).ignore();',
    replace: '    listened.toString();',
    test: 'test/history_report_test.dart',
    name: 'another song — history gets how long the previous one played',
  ),
  (
    what: 'пауза считается прослушиванием',
    file: 'lib/player.dart',
    find: '    _playingSince = next == AudioPhase.playing ? now : null;',
    replace: '    _playingSince = now;',
    test: 'test/history_report_test.dart',
    name: 'a pause does not count and sends what was heard by itself',
  ),
  (
    what: 'пауза не отправляет услышанное',
    file: 'lib/player.dart',
    find:
        '    if (was == AudioPhase.playing && _phase == AudioPhase.paused) {\n'
        '      _report();\n'
        '    }',
    replace:
        '    if (was == AudioPhase.playing && _phase == AudioPhase.paused) {}',
    test: 'test/history_report_test.dart',
    name: 'a pause does not count and sends what was heard by itself',
  ),
  (
    what: '«повторить» после обрыва начинает прослушивание заново',
    file: 'lib/player.dart',
    find:
        '    if (!auto && (track.id != _current?.id || from == Duration.zero)) {',
    replace: '    if (!auto) {',
    test: 'test/history_report_test.dart',
    name: 'retry after a drop continues the same listen',
  ),
  (
    what: 'плеер приложения не подключён к истории',
    file: 'lib/app.dart',
    find: '    listened: _listened,',
    replace: '    listened: null,',
    test: 'test/history_report_test.dart',
    name: 'in app: POST /v1/history with launch count (D1)',
  ),
  (
    what: '503 показан не как «сервер недоступен»',
    file: 'lib/server_api.dart',
    find: '      503 => ServerFailure.unavailable,',
    replace: '      503 => ServerFailure.noAnswer,',
    test: 'test/server_errors_test.dart',
    name:
        '503 — "server unavailable" and a working retry button, not "empty" genres',
  ),
  (
    what: 'отказ сервера показан как пустой список',
    file: 'lib/screens/catalog_screens.dart',
    find: '          load: services.server.genres,',
    replace:
        '          load: () => services.server.genres()'
        '.catchError((Object _) => <Genre>[]),',
    test: 'test/server_errors_test.dart',
    name:
        '503 — "server unavailable" and a working retry button, not "empty" genres',
  ),
  (
    what: '«Повторить» ничего не делает',
    file: 'lib/screens/parts.dart',
    find:
        '            onRetry: reason == ServerFailure.notFound ? null : _reload,',
    replace:
        '            onRetry: reason == ServerFailure.notFound ? null : () {},',
    test: 'test/server_errors_test.dart',
    name:
        '503 — "server unavailable" and a working retry button, not "empty" genres',
  ),
  (
    what: 'на 404 предложен бесполезный «Повторить»',
    file: 'lib/screens/parts.dart',
    find:
        '            onRetry: reason == ServerFailure.notFound ? null : _reload,',
    replace: '            onRetry: _reload,',
    test: 'test/server_errors_test.dart',
    name: '404 — own wording, no useless retry button artist',
  ),
  (
    what: 'после 409 плейлист не перечитан',
    file: 'lib/screens/library_screens.dart',
    find:
        '      await _server.orderPlaylist(widget.id, trackIds);\n'
        '    } on ServerFailed catch (failed) {\n'
        '      reload();\n',
    replace:
        '      await _server.orderPlaylist(widget.id, trackIds);\n'
        '    } on ServerFailed catch (failed) {\n',
    test: 'test/server_errors_test.dart',
    name: '409 on a new order — playlist reloaded and the reason shown',
  ),
  (
    what: 'запросы к серверу уходят без ключа',
    file: 'lib/server_api.dart',
    find:
        '      ...tokens.headersFor(uri),\n'
        '      if (body != null) \'content-type\': \'application/json\',\n'
        '      \'accept-language\': ?lang,',
    replace:
        '      if (body != null) \'content-type\': \'application/json\',\n'
        '      \'accept-language\': ?lang,',
    test: 'test/browse_screens_test.dart',
    name:
        'catalog chain genres → artists → artist → album: paths and session token',
  ),
  (
    what: 'длинный список не догружается',
    file: 'lib/screens/parts.dart',
    find: '        unawaited(Future.microtask(_more));\n',
    replace: '',
    test: 'test/browse_screens_test.dart',
    name: 'catalog artists load in chunks as the list scrolls',
  ),
  (
    what: 'в интерфейс попало слово про $_stemи',
    file: 'lib/screens/parts.dart',
    find: '    ServerFailure.unavailable => t.partsServerUnavailable,',
    replace: "    ServerFailure.unavailable => '$_capStemа недоступна',",
    test: 'test/privacy_ui_test.dart',
    name: 'the app strings have no words about releases',
  ),
  (
    what: 'текст с названием уходит в лог',
    file: 'lib/screens/parts.dart',
    find: '  messenger.showSnackBar(SnackBar(content: Text(text)));',
    replace:
        '  debugPrint(text);\n'
        '  messenger.showSnackBar(SnackBar(content: Text(text)));',
    test: 'test/privacy_ui_test.dart',
    name: 'lib/ has no log output: no titles, artists or ids',
  ),
  (
    what: 'якорь select-plays для телефона сдвинут',
    file: 'lib/app.dart',
    find:
        '      onSelect: (tracks, index) =>\n'
        '              unawaited(_player.playQueue(tracks, start: index)),',
    replace:
        '      onSelect: (tracks, index) => unawaited(\n'
        '        _player.playQueue(tracks, start: index),\n'
        '      ),',
    test: 'test/device_anchors_test.dart',
    name: 'all phone negative-control anchors are found, each once',
  ),
];

/// `--anchors`: без тестов проверяет, что портимый кусок есть в файле ровно
/// один раз. Мёртвая запись молча ничего не сторожит.
Never anchors() {
  final dead = <String>[];
  for (final (n, m) in mutations.indexed) {
    final found = m.find.allMatches(File(m.file).readAsStringSync()).length;
    if (found != 1) {
      dead.add(
        '${n + 1}/${mutations.length} ${m.what}: $found раз в ${m.file}',
      );
    }
  }
  if (dead.isEmpty) {
    stdout.writeln('anchors ok: ${mutations.length} записей');
    exit(0);
  }
  for (final d in dead) {
    stdout.writeln('МЁРТВАЯ  $d');
  }
  exit(1);
}

Future<void> main(List<String> args) async {
  if (args.contains('--anchors')) {
    anchors();
  }
  final originals = <String, String>{};
  // Прерванный прогон не должен оставить приложение сломанным.
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) {
      originals.forEach((path, text) => File(path).writeAsStringSync(text));
      exit(130);
    });
  }

  final missed = <String>[];
  for (final (n, m) in mutations.indexed) {
    final label = '${n + 1}/${mutations.length} ${m.what}';
    final original = originals[m.file] ??= File(m.file).readAsStringSync();
    final found = m.find.allMatches(original).length;
    if (found != 1) {
      stdout.writeln(
        'НЕ НАЙДЕНО  $label: кусок в ${m.file} встречается $found раз',
      );
      missed.add(label);
      continue;
    }
    File(m.file).writeAsStringSync(original.replaceFirst(m.find, m.replace));
    final bool red;
    try {
      red = await fails(m.test, m.name);
    } finally {
      File(m.file).writeAsStringSync(original);
    }
    stdout.writeln('${red ? 'красный' : 'НЕ КРАСНЫЙ'}  $label → «${m.name}»');
    if (!red) {
      missed.add(label);
    }
  }

  final all = await Process.run('flutter', ['test']);
  stdout.writeln(
    all.exitCode == 0
        ? 'после отката весь набор зелёный'
        : 'после отката набор НЕ зелёный:\n${all.stdout}',
  );
  if (missed.isNotEmpty || all.exitCode != 0) {
    stdout.writeln('negative control FAILED: ${missed.join('; ')}');
    exit(1);
  }
  stdout.writeln('negative control ok');
  exit(0);
}

/// Упал ли названный тест. Запускается только он.
Future<bool> fails(String test, String name) async {
  final run = await Process.run('flutter', [
    'test',
    test,
    '--plain-name',
    name,
    '--reporter',
    'json',
  ], stdoutEncoding: utf8);
  final names = <int, String>{};
  final failed = <String>{};
  for (final line in LineSplitter.split(run.stdout as String)) {
    if (!line.startsWith('{')) {
      continue;
    }
    switch (jsonDecode(line)) {
      case {
        'type': 'testStart',
        'test': {'id': final int id, 'name': final String name},
      }:
        names[id] = name;
      case {'type': 'testDone', 'testID': final int id, 'result': != 'success'}:
        failed.add(names[id]!);
    }
  }
  return failed.contains(name);
}
