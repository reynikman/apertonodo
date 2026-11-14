import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/auth/foreign_login.dart';
import 'package:music_stream/auth/login.dart';
import 'package:music_stream/screens/login_screen.dart';
import 'package:music_stream/server_kind.dart';

/// FT-776: login to foreign server — Navidrome (Subsonic) or Jellyfin.
///
/// Wizard auto-detects server type at address (`detectServer`, FT-651). Own
/// server uses legacy login, foreign server — `onForeignLogin` with username and password.
/// Plain `http` permitted only for home network addresses (owner directive
/// 12.10): password not transmitted over plain internet.
void main() {
  final address = find.byKey(const Key('server-address-field'));
  final next = find.byKey(const Key('server-address-next'));
  final user = find.byKey(const Key('login-username'));
  final password = find.byKey(const Key('login-password'));
  final submit = find.byKey(const Key('login-submit'));
  final addressError = find.byKey(const Key('wizard-address-error'));

  late List<Uri> own;
  late List<ForeignLogin> foreign;

  Future<void> open(WidgetTester tester, ServerKind kind) async {
    own = [];
    foreign = [];
    await tester.pumpWidget(
      LoginWizard(
        onLogin: (server, _, _) async => own.add(server),
        detect: (origin) async => DetectedServer(kind: kind, base: origin),
        onForeignLogin: (login) async => foreign.add(login),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> signIn(WidgetTester tester, String at) async {
    await tester.enterText(address, at);
    await tester.pump();
    await tester.tap(next);
    await tester.pumpAndSettle();
    await tester.enterText(user, 'anna');
    await tester.enterText(password, 'secret');
    await tester.pump();
    await tester.tap(submit);
    await tester.pumpAndSettle();
  }

  testWidgets('Navidrome on local LAN via http: foreign login', (tester) async {
    await open(tester, ServerKind.subsonic);
    await signIn(tester, 'http://192.168.1.10:4533');

    expect(own, isEmpty, reason: 'foreign server never gets own auth');
    expect(foreign, hasLength(1));
    expect(foreign.single.kind, ServerKind.subsonic);
    expect(foreign.single.base, Uri.parse('http://192.168.1.10:4533'));
    expect(foreign.single.username, 'anna');
    expect(foreign.single.password, 'secret');
  });

  testWidgets('Jellyfin: also foreign login', (tester) async {
    await open(tester, ServerKind.jellyfin);
    await signIn(tester, 'https://music.example.org');

    expect(own, isEmpty);
    expect(foreign.single.kind, ServerKind.jellyfin);
  });

  testWidgets('own server uses standard login', (tester) async {
    await open(tester, ServerKind.apertonodo);
    await signIn(tester, 'https://music.example.org');

    expect(foreign, isEmpty);
    expect(own, [Uri.parse('https://music.example.org')]);
  });

  testWidgets('plain http to public internet disallowed', (tester) async {
    await open(tester, ServerKind.subsonic);
    await tester.enterText(address, 'http://8.8.8.8:4533');
    await tester.pump();
    await tester.tap(next);
    await tester.pumpAndSettle();

    expect(addressError, findsOneWidget);
    expect(user, findsNothing);
  });

  test('http allowed only for local network', () {
    for (final ok in [
      'http://192.168.1.10:4533',
      'http://10.0.0.5',
      'http://172.16.0.2:8096',
      'http://172.31.255.1',
      'http://nas.local:4533',
      'http://127.0.0.1:8080',
      'https://music.example.org',
    ]) {
      expect(serverOrigin(ok), isNotNull, reason: ok);
    }
    for (final bad in [
      'http://172.32.0.1',
      'http://8.8.8.8',
      'http://music.example.org',
      'http://192.168.1.10.example.org',
    ]) {
      expect(serverOrigin(bad), isNull, reason: bad);
    }
  });

  test('Android allows cleartext http via validation check', () {
    final config = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    ).readAsStringSync();
    expect(
      RegExp(
        r'<base-config[^>]*cleartextTrafficPermitted="true"',
      ).hasMatch(config),
      isTrue,
      reason: 'without this local Navidrome over http will not open',
    );
  });
}
