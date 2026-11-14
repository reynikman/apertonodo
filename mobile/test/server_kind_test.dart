import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/server_kind.dart';

/// Lead check FT-651: detect server type at URL entered by user.

const _health = '{"status":"ok"}';

/// Responses mirror real servers: Jellyfin 10.10 and Navidrome 0.53 match lead containers,
/// Emby matches API specification (live Emby not queried).
const _jellyfin =
    '{"LocalAddress":"http://172.17.0.2:8096","ServerName":"srv","Version":"10.10.7",'
    '"ProductName":"Jellyfin Server","OperatingSystem":"","Id":"0123456789abcdef0123456789abcdef",'
    '"StartupWizardCompleted":true}';
const _emby =
    '{"LocalAddress":"http://172.17.0.3:8096","ServerName":"srv","Version":"4.8.11.0",'
    '"Id":"fedcba9876543210fedcba9876543210"}';
const _navidrome =
    '{"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome",'
    '"serverVersion":"0.53.3 (13af8ed4)","openSubsonic":true,'
    '"error":{"code":10,"message":"Missing required parameter \\"u\\""}}}';
const _subsonicOk = '{"subsonic-response":{"status":"ok","version":"1.15.0"}}';
const _html = '<!doctype html><html><body>router</body></html>';

typedef _Answer = FutureOr<http.Response> Function(http.Request request);

http.Response _json(
  String body, {
  int status = 200,
  Map<String, String>? headers,
}) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json', ...?headers},
);

http.Response _page([int status = 200]) =>
    http.Response(_html, status, headers: {'content-type': 'text/html'});

class _Net {
  _Net(this.answer);
  final _Answer answer;
  final seen = <http.Request>[];
  late final client = MockClient((request) async {
    seen.add(request);
    return answer(request);
  });
  List<String> get urls => [for (final r in seen) r.url.toString()];
}

/// Server of single kind on one scheme and path: all else returns 404.
_Net _server(
  String body,
  String path, {
  String scheme = 'https',
  String prefix = '',
  int status = 200,
}) => _Net((request) {
  if (request.url.scheme != scheme) throw const SocketException('refused');
  return request.url.path == '$prefix$path'
      ? _json(body, status: status)
      : _page(404);
});

Future<ServerDetectFailure> _fails(Future<Object?> run) async {
  try {
    await run;
  } on ServerDetectError catch (error) {
    return error.kind;
  }
  fail('rejection expected');
}

ServerDetectFailure _badAddress(String input) {
  try {
    serverAddressCandidates(input);
  } on ServerDetectError catch (error) {
    return error.kind;
  }
  fail('"$input" must not be considered a valid address');
}

/// Server streaming chunked response indefinitely: track count of consumed chunks.
class _Flood extends http.BaseClient {
  int taken = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> body() async* {
      for (var i = 0; i < 5000; i++) {
        taken++;
        yield List<int>.filled(1024, 0x20);
      }
    }

    return http.StreamedResponse(body(), 200);
  }
}

void main() {
  group('user-entered server address', () {
    test('without scheme: https first, then http', () {
      expect(
        serverAddressCandidates('music.example.org').map((u) => u.toString()),
        ['https://music.example.org', 'http://music.example.org'],
      );
      expect(
        serverAddressCandidates('192.168.1.10:4533').map((u) => u.toString()),
        ['https://192.168.1.10:4533', 'http://192.168.1.10:4533'],
      );
    });

    test('with scheme: explicit only, no silent http/https replacement', () {
      expect(
        serverAddressCandidates(
          'http://nas.local:8096',
        ).map((u) => u.toString()),
        ['http://nas.local:8096'],
      );
      expect(
        serverAddressCandidates('https://nas.local').map((u) => u.toString()),
        ['https://nas.local'],
      );
      expect(
        serverAddressCandidates('HTTPS://Nas.Local').map((u) => u.toString()),
        ['https://nas.local'],
      );
    });

    test('strip edge spaces, trailing slashes, query/hash; keep path', () {
      expect(
        serverAddressCandidates(
          '  https://example.org/music/  \n',
        ).single.toString(),
        'https://example.org/music',
      );
      expect(
        serverAddressCandidates('https://example.org///').single.toString(),
        'https://example.org',
      );
      expect(
        serverAddressCandidates(
          'https://example.org/a//b/?x=1#top',
        ).single.toString(),
        'https://example.org/a/b',
      );
      expect(
        serverAddressCandidates('example.org/navidrome/')[1].toString(),
        'http://example.org/navidrome',
      );
      expect(
        serverAddressCandidates('https://[::1]:4533/').single.toString(),
        'https://[::1]:4533',
      );
    });

    test('invalid address', () {
      for (final input in [
        '',
        '   ',
        'https://',
        'http:///path',
        'ftp://example.org',
        'file:///etc/passwd',
        'javascript://alert(1)',
        'my server.local',
        'https://exa mple.org',
        'https://example.org:port',
        'https://example.org:99999',
        '://example.org',
        'https://${'a' * 2050}.org',
      ]) {
        expect(
          _badAddress(input),
          ServerDetectFailure.badAddress,
          reason: input,
        );
      }
    });

    test('malformed IPv6 in brackets is invalid address, not error', () {
      for (final input in [
        '[:]',
        '[::1*]',
        '[[[]',
        'https://[zz]:80/x',
        '[,:..]',
      ]) {
        expect(
          _badAddress(input),
          ServerDetectFailure.badAddress,
          reason: input,
        );
      }
    });

    test('credentials in address rejected', () {
      expect(
        _badAddress('https://alice:secret@example.org'),
        ServerDetectFailure.badAddress,
      );
      expect(_badAddress('alice@example.org'), ServerDetectFailure.badAddress);
    });

    test('invalid address: no network calls', () async {
      final net = _Net((_) => _json(_health));
      expect(
        await _fails(detectServer('ftp://example.org', client: net.client)),
        ServerDetectFailure.badAddress,
      );
      expect(
        await _fails(detectServer(' ', client: net.client)),
        ServerDetectFailure.badAddress,
      );
      expect(net.seen, isEmpty);
    });
  });

  group('server detection', () {
    test('Apertonodo', () async {
      final net = _server(_health, '/v1/health');
      final found = await detectServer('example.org', client: net.client);
      expect(found.kind, ServerKind.apertonodo);
      expect(found.base.toString(), 'https://example.org');
      expect(found.insecure, isFalse);
      expect(found.version, isNull);
      expect(net.urls, ['https://example.org/v1/health']);
    });

    test('Apertonodo: edition parsed from header', () async {
      final net = _Net(
        (_) => _json(_health, headers: {'x-flowtune-revision': 'abc1234'}),
      );
      expect(
        (await detectServer('https://example.org', client: net.client)).version,
        'abc1234',
      );
    });

    test('Jellyfin', () async {
      final net = _server(_jellyfin, '/System/Info/Public');
      final found = await detectServer('example.org', client: net.client);
      expect(found.kind, ServerKind.jellyfin);
      expect(found.product, 'Jellyfin Server');
      expect(found.version, '10.10.7');
      expect(net.urls, [
        'https://example.org/v1/health',
        'https://example.org/System/Info/Public',
      ]);
    });

    test('Emby: response without product name is distinct type', () async {
      final found = await detectServer(
        'example.org',
        client: _server(_emby, '/System/Info/Public').client,
      );
      expect(found.kind, ServerKind.emby);
      expect(found.version, '4.8.11.0');
    });

    test('Navidrome: "missing name" rejection is still Subsonic', () async {
      final net = _server(_navidrome, '/rest/ping.view');
      final found = await detectServer('example.org', client: net.client);
      expect(found.kind, ServerKind.subsonic);
      expect(found.product, 'navidrome');
      expect(found.version, '0.53.3 (13af8ed4)');
      expect(net.urls.last, startsWith('https://example.org/rest/ping.view?'));
      expect(net.seen.last.url.queryParameters, {
        'f': 'json',
        'v': '1.16.1',
        'c': 'apertono',
      });
    });

    test(
      'legacy Subsonic: no product name, protocol version used; 4xx status rejection accepted',
      () async {
        final found = await detectServer(
          'example.org',
          client: _server(_subsonicOk, '/rest/ping.view').client,
        );
        expect(found.kind, ServerKind.subsonic);
        expect(found.product, isNull);
        expect(found.version, '1.15.0');
        final refused = await detectServer(
          'example.org',
          client: _server(_navidrome, '/rest/ping.view', status: 401).client,
        );
        expect(refused.kind, ServerKind.subsonic);
      },
    );

    test('server under subpath: path kept in base and requests', () async {
      final net = _server(_navidrome, '/rest/ping.view', prefix: '/music');
      final found = await detectServer(
        'https://example.org/music/',
        client: net.client,
      );
      expect(found.base.toString(), 'https://example.org/music');
      expect(net.urls.first, 'https://example.org/music/v1/health');
    });

    test('requests without credentials or keys; GET only', () async {
      final net = _server(_navidrome, '/rest/ping.view');
      await detectServer('example.org', client: net.client);
      for (final request in net.seen) {
        expect(request.method, 'GET');
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-flowtune-key')),
        );
        expect(
          request.url.queryParameters.keys,
          isNot(
            anyOf(
              contains('u'),
              contains('p'),
              contains('t'),
              contains('apiKey'),
            ),
          ),
        );
      }
    });
  });

  group('https and http', () {
    test('https fails - try http and report unencrypted connection', () async {
      final net = _server(_navidrome, '/rest/ping.view', scheme: 'http');
      final found = await detectServer('192.168.1.10:4533', client: net.client);
      expect(found.base.toString(), 'http://192.168.1.10:4533');
      expect(found.insecure, isTrue);
      expect(net.urls.first, 'https://192.168.1.10:4533/v1/health');
      expect(
        net.urls.where((u) => u.startsWith('https:')),
        hasLength(1),
        reason: 'do not query dead scheme three times',
      );
    });

    test('https returned foreign page, server on http - detected', () async {
      final net = _Net(
        (request) => request.url.scheme == 'https' ? _page() : _json(_health),
      );
      final found = await detectServer('example.org', client: net.client);
      expect(found.base.toString(), 'http://example.org');
      expect(found.kind, ServerKind.apertonodo);
    });

    test('user specified https - do not fall back to http', () async {
      final net = _server(_health, '/v1/health', scheme: 'http');
      expect(
        await _fails(detectServer('https://example.org', client: net.client)),
        ServerDetectFailure.unreachable,
      );
      expect(net.urls.every((u) => u.startsWith('https:')), isTrue);
    });

    test('user specified http - do not try https', () async {
      final net = _server(_health, '/v1/health', scheme: 'http');
      final found = await detectServer(
        'http://example.org',
        client: net.client,
      );
      expect(found.insecure, isTrue);
      expect(net.urls, ['http://example.org/v1/health']);
    });
  });

  group('not found', () {
    test('no response - marked "unavailable"', () async {
      final net = _Net((_) => throw const SocketException('refused'));
      expect(
        await _fails(detectServer('example.org', client: net.client)),
        ServerDetectFailure.unreachable,
      );
      expect(net.seen, hasLength(2));
    });

    test(
      'client error yields "unavailable", not unhandled exception',
      () async {
        for (final Object error in [
          http.ClientException('x'),
          const HandshakeException('cert'),
          const FormatException('x'),
          TimeoutException('x'),
        ]) {
          final net = _Net((_) => throw error);
          expect(
            await _fails(detectServer('example.org', client: net.client)),
            ServerDetectFailure.unreachable,
          );
        }
      },
    );

    test('server silent - do not wait past timeout', () async {
      final net = _Net((_) => Completer<http.Response>().future);
      final watch = Stopwatch()..start();
      final failure = await _fails(
        detectServer(
          'https://example.org',
          client: net.client,
          timeout: const Duration(milliseconds: 40),
        ),
      );
      expect(failure, ServerDetectFailure.unreachable);
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(net.seen, hasLength(1));
    });

    test('responded but not music server - "unknown server"', () async {
      final net = _Net((_) => _page());
      expect(
        await _fails(detectServer('https://example.org', client: net.client)),
        ServerDetectFailure.unknown,
      );
      expect(net.seen, hasLength(3));
    });

    test(
      'https foreign, http dead - "unknown server", not "unavailable"',
      () async {
        final net = _Net(
          (request) => request.url.scheme == 'https'
              ? _page(404)
              : throw const SocketException('x'),
        );
        expect(
          await _fails(detectServer('example.org', client: net.client)),
          ServerDetectFailure.unknown,
        );
      },
    );

    test('similar but wrong', () async {
      for (final (path, body, status) in [
        ('/v1/health', '{"status":"down"}', 200),
        ('/v1/health', '{"status":"ok"}', 503),
        ('/v1/health', '["ok"]', 200),
        ('/v1/health', '"ok"', 200),
        ('/v1/health', '{"status":"ok"', 200),
        ('/System/Info/Public', '{"Version":"1.0"}', 200),
        ('/System/Info/Public', '{"Id":"abc"}', 200),
        ('/System/Info/Public', '{"Id":7,"Version":"1.0"}', 200),
        ('/System/Info/Public', '{"Id":"abc","Version":""}', 200),
        ('/System/Info/Public', _jellyfin, 401),
        ('/rest/ping.view', '{"subsonic-response":"ok"}', 200),
        ('/rest/ping.view', '{"subsonic-response":{"status":"maybe"}}', 200),
        ('/rest/ping.view', '{"subsonic-response":{}}', 200),
        ('/rest/ping.view', _navidrome, 502),
        ('/rest/ping.view', '<subsonic-response status="ok"/>', 200),
      ]) {
        final net = _server(body, path, status: status);
        expect(
          await _fails(detectServer('https://example.org', client: net.client)),
          ServerDetectFailure.unknown,
          reason: '$path $status $body',
        );
      }
    });

    test('do not parse oversized response', () async {
      expect(serverProbeMaxBytes, 64 * 1024);
      final huge = '{"status":"ok","pad":"${'x' * serverProbeMaxBytes}"}';
      final net = _server(huge, '/v1/health');
      expect(
        await _fails(detectServer('https://example.org', client: net.client)),
        ServerDetectFailure.unknown,
      );
      final fits =
          '{"status":"ok","pad":"${'x' * (serverProbeMaxBytes - 40)}"}';
      expect(
        (await detectServer(
          'https://example.org',
          client: _server(fits, '/v1/health').client,
        )).kind,
        ServerKind.apertonodo,
      );
    });

    test('corrupted response bytes: not that server, no crash', () async {
      final net = _Net((_) => http.Response.bytes([0xff, 0xfe, 0x7b], 200));
      expect(
        await _fails(detectServer('https://example.org', client: net.client)),
        ServerDetectFailure.unknown,
      );
    });
  });

  group('display info', () {
    test('Cyrillic in title parsed as UTF-8', () async {
      final body =
          '{"subsonic-response":{"status":"ok","version":"1.16.1","type":"Музыка"}}';
      final found = await detectServer(
        'https://example.org',
        client: _server(body, '/rest/ping.view').client,
      );
      expect(found.product, 'Музыка');
    });

    test('server declared wrong encoding - body still parsed as UTF-8', () async {
      final body =
          '{"subsonic-response":{"status":"ok","version":"1.16.1","type":"Музыка"}}';
      final net = _Net(
        (_) => http.Response.bytes(
          utf8.encode(body),
          200,
          headers: {'content-type': 'text/plain; charset=iso-8859-1'},
        ),
      );
      expect(
        (await detectServer('https://example.org', client: net.client)).product,
        'Музыка',
      );
    });

    test('title or version over 100 chars or not string: empty', () async {
      final long = 'v' * 101;
      final body =
          '{"subsonic-response":{"status":"ok","version":"$long","type":7,"serverVersion":["x"]}}';
      final found = await detectServer(
        'https://example.org',
        client: _server(body, '/rest/ping.view').client,
      );
      expect(found.kind, ServerKind.subsonic);
      expect(found.product, isNull);
      expect(found.version, isNull);
      final jelly = '{"Id":"abc","Version":"$long"}';
      expect(
        await _fails(
          detectServer(
            'https://example.org',
            client: _server(jelly, '/System/Info/Public').client,
          ),
        ),
        ServerDetectFailure.unknown,
      );
    });

    test('error and result text do not leak address', () async {
      final net = _Net(
        (_) => throw const SocketException('secret.example.org'),
      );
      try {
        await detectServer('secret.example.org', client: net.client);
        fail('rejection expected');
      } on ServerDetectError catch (error) {
        expect(error.toString(), 'ServerDetectError(unreachable)');
      }
      final found = await detectServer(
        'secret.example.org',
        client: _server(_health, '/v1/health').client,
      );
      expect(found.toString(), 'DetectedServer(apertonodo)');
    });
  });
  group('second look', () {
    test(
      'no redirects followed; redirect itself is not server response',
      () async {
        // Otherwise http address redirecting to https is detected as http, exposing credentials.
        final net = _Net(
          (request) => request.url.path == '/rest/ping.view'
              ? _json(
                  _navidrome,
                  status: 302,
                  headers: {'location': 'https://x'},
                )
              : _page(301),
        );
        expect(
          await _fails(
            detectServer('http://music.example.org', client: net.client),
          ),
          ServerDetectFailure.unknown,
        );
        expect(net.seen, hasLength(3));
        expect(net.seen.every((r) => !r.followRedirects), isTrue);
      },
    );

    test('infinite body capped: read at most max limit', () async {
      final flood = _Flood();
      expect(
        await _fails(detectServer('https://music.example.org', client: flood)),
        ServerDetectFailure.unknown,
      );
      // Three probes, each capped at 64 KiB in 1 KiB chunks — with 1 chunk headroom.
      expect(flood.taken, lessThanOrEqualTo(3 * 66));
    });

    test('browser URL: page tail stripped', () async {
      final net = _server(_jellyfin, '/System/Info/Public', scheme: 'http');
      final found = await detectServer(
        'http://192.168.1.5:8096/web/index.html#!/home.html',
        client: net.client,
      );
      expect(found.kind, ServerKind.jellyfin);
      expect(found.base.toString(), 'http://192.168.1.5:8096');
    });

    test('server under subpath found before root; page tail ignored', () async {
      final net = _Net((request) {
        if (request.url.path == '/jellyfin/System/Info/Public') {
          return _json(_jellyfin);
        }
        if (request.url.path == '/rest/ping.view') return _json(_navidrome);
        return _page(404);
      });
      final found = await detectServer(
        'https://example.org/jellyfin/web/',
        client: net.client,
      );
      expect(found.kind, ServerKind.jellyfin);
      expect(found.base.toString(), 'https://example.org/jellyfin');
    });

    test('dead server: do not try parent paths', () async {
      final net = _Net((_) => throw const SocketException('refused'));
      expect(
        await _fails(
          detectServer('https://example.org/a/b/c', client: net.client),
        ),
        ServerDetectFailure.unreachable,
      );
      expect(net.urls, ['https://example.org/a/b/c/v1/health']);
    });

    test('deep path: traverse up at most 3 steps', () async {
      final net = _Net((_) => _page(404));
      expect(
        await _fails(
          detectServer('https://example.org/a/b/c/d/e/f', client: net.client),
        ),
        ServerDetectFailure.unknown,
      );
      expect(net.seen, hasLength(4 * 3));
    });

    test('query and fragment stripped before URL parse', () {
      String only(String input) =>
          serverAddressCandidates(input).last.toString();
      expect(only('host:8096#!/home'), 'http://host:8096');
      expect(only('host/x?next=https://a'), 'http://host/x');
      expect(only('host?mail=a@b'), 'http://host');
      expect(only('https://host/app/#/album/1?x=a@b'), 'https://host/app');
      expect(_badAddress('#home'), ServerDetectFailure.badAddress);
      expect(_badAddress('user@host?x=1'), ServerDetectFailure.badAddress);
    });

    test('do not show name with newlines or bidi text overrides', () async {
      Future<DetectedServer> ask(String type) => detectServer(
        'https://example.org',
        client: _server(
          jsonEncode({
            'subsonic-response': {
              'status': 'ok',
              'version': '1.16.1',
              'type': type,
            },
          }),
          '/rest/ping.view',
        ).client,
      );
      expect((await ask('navi\ndrome')).product, isNull);
      expect((await ask('navi\u202edrome')).product, isNull);
      expect((await ask('  navidrome  ')).product, 'navidrome');
    });
  });
}
