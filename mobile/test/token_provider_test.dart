import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/auth/token_provider.dart';

class MemorySessionStore extends SessionStore {
  String? token;

  @override
  Future<void> saveToken(String token) async => this.token = token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> clear() async => token = null;
}

void main() {
  test('401 clears bearer and signIn restores the new bearer', () async {
    final server = Uri.parse('https://apertono.test');
    final store = MemorySessionStore();
    final tokens = TokenProvider(store, server: server);
    final oldToken = DateTime.now().microsecondsSinceEpoch.toString();
    final newToken = '$oldToken-next';

    await tokens.signIn(oldToken);
    expect(tokens.headersFor(server), {'authorization': 'Bearer $oldToken'});

    await tokens.onUnauthorized();
    expect(tokens.headersFor(server), isEmpty);

    await tokens.signIn(newToken);
    expect(store.token, newToken);
    expect(tokens.headersFor(server), {'authorization': 'Bearer $newToken'});
  });

  test('bearer is withheld from insecure and foreign origins', () async {
    final token = DateTime.now().microsecondsSinceEpoch.toString();
    final insecureServer = Uri.parse('http://apertono.test');
    final insecureTokens = TokenProvider(
      MemorySessionStore(),
      server: insecureServer,
    );
    await insecureTokens.signIn(token);
    expect(insecureTokens.headersFor(insecureServer), isEmpty);

    final loopbackServer = Uri.parse('http://127.0.0.1:8088');
    final loopbackTokens = TokenProvider(
      MemorySessionStore(),
      server: loopbackServer,
    );
    final loopbackToken = '$token-loopback';
    await loopbackTokens.signIn(loopbackToken);
    expect(loopbackTokens.headersFor(loopbackServer), {
      'authorization': 'Bearer $loopbackToken',
    });

    final secureServer = Uri.parse('https://apertono-a.test');
    final secureTokens = TokenProvider(
      MemorySessionStore(),
      server: secureServer,
    );
    await secureTokens.signIn('$token-secure');
    expect(
      secureTokens.headersFor(Uri.parse('https://apertono-b.test')),
      isEmpty,
    );
  });

  // Login accepts a home-network server over http (isHomeNetworkHost); if the
  // bearer were withheld there, every request after login is 401 and the app
  // says "session expired" right after signing in.
  test('bearer reaches a home-network server over http', () async {
    for (final address in [
      'http://192.168.1.20:8088',
      'http://10.0.0.5:8088',
      'http://nas:8088',
      'http://music.local:8088',
    ]) {
      final server = Uri.parse(address);
      final tokens = TokenProvider(MemorySessionStore(), server: server);
      await tokens.signIn('home-token');
      expect(tokens.headersFor(server), {
        'authorization': 'Bearer home-token',
      }, reason: address);
    }
    final public = Uri.parse('http://203.0.113.7:8088');
    final publicTokens = TokenProvider(MemorySessionStore(), server: public);
    await publicTokens.signIn('home-token');
    expect(publicTokens.headersFor(public), isEmpty);
  });
}
