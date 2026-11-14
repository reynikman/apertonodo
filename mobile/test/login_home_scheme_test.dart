import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/auth/login.dart';

/// FT-776: address without scheme — home network gets `http://`, others get `https://`.
void main() {
  test('home address without scheme — http', () {
    expect(schemeFor('192.168.1.10:4533'), 'http://');
    expect(schemeFor('nas.local'), 'http://');
    expect(schemeFor('10.0.0.5/jellyfin'), 'http://');
  });

  test('public address and spoofed name — https', () {
    expect(schemeFor('music.example.org'), 'https://');
    expect(schemeFor('192.168.1.10.example.org'), 'https://');
  });

  // Owner 13.10: no "home network" switch — the app tells a home address itself,
  // so it has to know every shape of one.
  test('short name and overlay network — http', () {
    expect(schemeFor('nas:8088'), 'http://');
    expect(schemeFor('my-server'), 'http://');
    expect(schemeFor('100.101.102.103:8088'), 'http://');
    expect(serverOrigin('http://nas:8088'), isNotNull);
    expect(serverOrigin('http://100.64.0.1'), isNotNull);
  });

  test('public address over http is still refused', () {
    expect(schemeFor('100.63.0.1'), 'https://');
    expect(schemeFor('100.128.0.1'), 'https://');
    expect(serverOrigin('http://music.example.org'), isNull);
    expect(serverOrigin('http://8.8.8.8'), isNull);
    expect(serverOrigin('http://100.128.0.1'), isNull);
  });
}
