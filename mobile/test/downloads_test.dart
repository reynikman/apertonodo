import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';
import 'package:music_stream/downloads.dart';

class MemorySessionStore extends SessionStore {
  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> clear() async {}
}

void main() {
  test('redirect to another origin does not forward the bearer', () async {
    final token = DateTime.now().microsecondsSinceEpoch.toString();
    final server = Uri.parse('https://apertono.test/audio');
    final foreign = Uri.parse('https://cdn.test/audio');
    final tokens = TokenProvider(MemorySessionStore(), server: server);
    await tokens.signIn(token);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url == server) {
        return http.Response(
          '',
          302,
          headers: {'location': foreign.toString()},
        );
      }
      return http.Response('audio', 200);
    });

    final response = await openDownload(server, tokens: tokens, client: client);
    await response.stream.drain<void>();

    expect(response.statusCode, 200);
    expect(requests, hasLength(2));
    expect(requests[0].headers['authorization'], 'Bearer $token');
    expect(requests[1].url, foreign);
    expect(requests[1].headers['authorization'], isNull);
  });

  test('same-origin redirect keeps the bearer', () async {
    final token = DateTime.now().microsecondsSinceEpoch.toString();
    final server = Uri.parse('https://apertono.test/audio');
    final redirected = Uri.parse('https://apertono.test/audio-final');
    final tokens = TokenProvider(MemorySessionStore(), server: server);
    await tokens.signIn(token);
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url == server) {
        return http.Response(
          '',
          302,
          headers: {'location': redirected.toString()},
        );
      }
      return http.Response('audio', 200);
    });

    final response = await openDownload(server, tokens: tokens, client: client);
    await response.stream.drain<void>();

    expect(response.statusCode, 200);
    expect(requests, hasLength(2));
    expect(requests[0].headers['authorization'], 'Bearer $token');
    expect(requests[1].url, redirected);
    expect(requests[1].headers['authorization'], 'Bearer $token');
  });
}
