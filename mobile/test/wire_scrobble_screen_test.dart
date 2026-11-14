import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/app.dart';

import 'fake_server.dart';

/// Wire FT-647: "ListenBrainz and Last.fm" in account menu opens
/// services screen, token synced to server.
void main() {
  Future<FakeServer> openScreen(WidgetTester tester) async {
    final server = FakeServer();
    await tester.pumpWidget(
      MusicApp(
        catalogSource: server.catalog(),
        server: server.api(),
        onAccountAction: (_) async {},
      ),
    );
    await tester.tap(find.byKey(const Key('tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scrobble')));
    await tester.pumpAndSettle();
    return server;
  }

  testWidgets('menu item opens screen with status of both services', (
    tester,
  ) async {
    final server = await openScreen(tester);

    expect(find.text('ListenBrainz и Last.fm'), findsWidgets);
    expect(server.calls('GET /v1/scrobble'), hasLength(1));
    expect(server.calls('GET /v1/scrobble/lastfm'), hasLength(1));
    expect(find.byKey(const Key('scrobble-lb-token')), findsOneWidget);
  });

  testWidgets('ListenBrainz token sent to server', (tester) async {
    final server = await openScreen(tester);

    await tester.enterText(
      find.byKey(const Key('scrobble-lb-token')),
      'test-token-test-token',
    );
    await tester.tap(find.byKey(const Key('scrobble-lb-connect')));
    await tester.pumpAndSettle();

    expect(server.bodies('POST /v1/scrobble/listenbrainz').single, {
      'token': 'test-token-test-token',
    });
    expect(find.text('Подключено'), findsOneWidget);
  });
}
