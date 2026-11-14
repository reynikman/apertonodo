import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';

/// Wire FT-693: track already in playlist — app prompts confirmation
/// rather than adding duplicate silently.
void main() {
  const found = '11111111-1111-1111-1111-111111111111';

  Future<Rig> addFromSearch(WidgetTester tester, {required bool inside}) async {
    final rig = Rig();
    rig.server.on('GET /v1/playlists/*', (_) {
      final body = sample('library-playlist');
      final tracks = body['tracks'] as List;
      if (inside) (tracks.first as Map<String, dynamic>)['id'] = found;
      return answer(200, body);
    });
    await rig.start(tester);
    await typeSearch(tester, 'metallica');
    await tapAndSettle(tester, find.byTooltip('Ещё').first);
    await tapAndSettle(tester, find.text('Добавить в плейлист'));
    await tapAndSettle(tester, find.text('В дорогу'));
    return rig;
  }

  testWidgets('duplicate song: prompt shown, Cancel sends nothing', (
    tester,
  ) async {
    final rig = await addFromSearch(tester, inside: true);

    expect(find.text('1 песня уже есть в плейлисте'), findsOneWidget);
    await tapAndSettle(tester, find.text('Отмена'));
    expect(rig.server.calls('POST /v1/playlists/*/tracks'), isEmpty);
  });

  testWidgets('duplicate song: Add All adds anyway', (tester) async {
    final rig = await addFromSearch(tester, inside: true);

    await tapAndSettle(tester, find.text('Добавить все'));
    expect(rig.server.calls('POST /v1/playlists/*/tracks'), hasLength(1));
  });

  testWidgets('new song not in playlist: added without prompt', (tester) async {
    final rig = await addFromSearch(tester, inside: false);

    expect(find.text('1 песня уже есть в плейлисте'), findsNothing);
    expect(rig.server.calls('POST /v1/playlists/*/tracks'), hasLength(1));
  });
}
