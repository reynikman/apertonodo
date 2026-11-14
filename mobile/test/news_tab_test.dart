import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/news_screen.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// FT-579 (P-A83): "News" tab — third of five; feed is read inside
/// app, only "Source" leads outside.
///
/// Contract:
/// - bar: `home`, `browse`, `news`, `search`, `library` (`tab-…` keys),
///   TalkBack announces "News"; on 360 dp five columns fit within island;
/// - `NewsScreen(services:)` in `lib/screens/news_screen.dart` loads
///   `GET /v1/news` (sample `contracts/news.response.json`);
/// - card `news-card-<id>`: channel, title, text start `news-text-<id>`
///   (long text collapsed, `maxLines` set); "Read full" `news-read-<id>`
///   opens article `news-article-<id>` inside app (FT-716, P-A111):
///   full text `news-article-text-<id>`, inside is "Source";
///   double tap opens article once; "Back" returns to feed;
/// - "Source" is only in article: `news-source-<id>` at bottom and
///   `news-source-top-<id>` top right call `Services.openLink(Uri)` —
///   sole external exit; title and text do not lead outside;
/// - for `release` card — `news-play-<id>`: album `album_id` from server
///   plays from first track; it has no "Source";
/// - empty feed is `news-empty`.
void main() {
  // News captions are bilingual (P-A84); Russian ones verified here.
  final dispatcher =
      TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
  setUp(() => dispatcher.localeTestValue = const Locale('ru'));
  tearDown(dispatcher.clearLocaleTestValue);
  // News consent already granted: consent screen is FT-581, here is feed.
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'news-consent': true,
      'news-enabled': true,
    }),
  );

  testWidgets('five tabs, «News» is third, fits in 360 width screen', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    usePhone(tester, phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/news', (_) => answer(200, sample('news')));
    await rig.start(tester);
    await tester.pumpAndSettle();

    const names = ['home', 'browse', 'news', 'search', 'library'];
    final rects = [
      for (final name in names) tester.getRect(find.byKey(Key('tab-$name'))),
    ];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right - 0.01));
    }
    final bar = tester.getRect(find.byKey(const Key('nav-bar')));
    expect(rects.first.left, greaterThanOrEqualTo(bar.left));
    expect(rects.last.right, lessThanOrEqualTo(bar.right));
    expect(
      find.descendant(
        of: find.byKey(const Key('nav-bar')),
        matching: find.bySemanticsLabel('Новости'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull, reason: 'bar overflowed');

    await openTab(tester, 'news');
    expect(find.byKey(const Key('news-card-101')), findsOneWidget);
    semantics.dispose();
  });

  Future<(Rig, List<Uri>)> feed(
    WidgetTester tester, {
    Future<void> Function()? linkDone,
  }) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/news', (_) => answer(200, sample('news')));
    final opened = <Uri>[];
    addTearDown(() => expect(rig.server.unknown, isEmpty));
    final server = rig.server.api();
    await tester.pumpWidget(
      MaterialApp(
        home: NewsScreen(
          services: Services(
            server: server,
            search: rig.server.catalog().search,
            play: (tracks, index) => rig.played.add((tracks, index)),
            prepare: (track) => rig.prepared.add(track.id),
            openLink: (uri) async {
              opened.add(uri);
              await linkDone?.call();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (rig, opened);
  }

  Finder inArticle(String id) => find.descendant(
    of: find.byKey(Key('news-article-$id')),
    matching: find.byType(Scrollable),
  );

  int? linesOf(WidgetTester tester, String id) =>
      tester.widget<Text>(find.byKey(Key('news-text-$id'))).maxLines;

  testWidgets('«Read full» opens complete article directly inside app', (
    tester,
  ) async {
    final (_, opened) = await feed(tester);

    expect(find.text('Loud Pages'), findsOneWidget);
    expect(
      linesOf(tester, '101'),
      isNotNull,
      reason: 'long text not collapsed in feed',
    );
    expect(
      find.byKey(const Key('news-source-101')),
      findsNothing,
      reason: '«Source» is inside article, not in feed',
    );

    final read = find.byKey(const Key('news-read-101'));
    await tester.ensureVisible(read);
    expect(
      find.descendant(of: read, matching: find.text('Читать полностью')),
      findsOneWidget,
    );
    await tapAndSettle(tester, read);

    final article = find.byKey(const Key('news-article-101'));
    expect(article, findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('news-article-text-101')))
          .maxLines,
      isNull,
      reason: 'article text is not complete',
    );
    expect(
      find.descendant(
        of: article,
        matching: find.text(
          'Quiet Lighthouse Orchestra announce a winter tour',
        ),
      ),
      findsOneWidget,
    );
    final articleText = find.byKey(const Key('news-article-text-101'));
    await tester.ensureVisible(articleText);
    await tapAndSettle(tester, articleText);
    expect(opened, isEmpty, reason: 'non-«Source» triggered link');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(article, findsNothing);
    expect(find.byKey(const Key('news-card-101')), findsOneWidget);
  });

  testWidgets('double tap opens article once', (tester) async {
    await feed(tester);
    final read = find.byKey(const Key('news-read-101'));
    await tester.ensureVisible(read);
    await tester.tap(read);
    await tester.tap(read, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('news-article-101')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('news-article-101')),
      findsNothing,
      reason: 'duplicate article opened underneath',
    );
  });

  testWidgets('tapping card title also opens complete article view', (
    tester,
  ) async {
    final (_, opened) = await feed(tester);
    await tapAndSettle(
      tester,
      find.text('Quiet Lighthouse Orchestra announce a winter tour'),
    );
    expect(find.byKey(const Key('news-article-101')), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('«Source» in article is the sole external exit link', (
    tester,
  ) async {
    final (_, opened) = await feed(tester);

    final read = find.byKey(const Key('news-read-101'));
    await tester.ensureVisible(read);
    await tapAndSettle(tester, read);
    final source = find.byKey(const Key('news-source-101'));
    await tester.scrollUntilVisible(source, 200, scrollable: inArticle('101'));
    await tapAndSettle(tester, source);
    expect(opened, [Uri.parse('https://loudpages.example.org/news/qlo-tour')]);
    await tapAndSettle(tester, find.byKey(const Key('news-source-top-101')));
    expect(opened.length, 2);
    expect(opened.last, opened.first);
    await tester.pageBack();
    await tester.pumpAndSettle();

    final telegram = find.byKey(const Key('news-read-103'));
    await tester.scrollUntilVisible(telegram, 300);
    await tapAndSettle(tester, telegram);
    final source103 = find.byKey(const Key('news-source-103'));
    await tester.scrollUntilVisible(
      source103,
      200,
      scrollable: inArticle('103'),
    );
    await tapAndSettle(tester, source103);
    expect(opened.last, Uri.parse('https://t.me/qlo_band/101'));
  });

  testWidgets('article shows channel in screen header', (tester) async {
    await feed(tester);
    final read = find.byKey(const Key('news-read-101'));
    await tester.ensureVisible(read);
    await tapAndSettle(tester, read);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Loud Pages'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'repeated «Source» tap while link opening — single external launch',
    (tester) async {
      var pending = Completer<void>();
      final (_, opened) = await feed(tester, linkDone: () => pending.future);
      final read = find.byKey(const Key('news-read-101'));
      await tester.ensureVisible(read);
      await tapAndSettle(tester, read);
      final top = find.byKey(const Key('news-source-top-101'));
      await tester.tap(top);
      await tester.pump();
      await tester.tap(top);
      await tester.pump();
      final bottom = find.byKey(const Key('news-source-101'));
      await tester.scrollUntilVisible(
        bottom,
        200,
        scrollable: inArticle('101'),
      );
      await tester.tap(bottom);
      await tester.pump();
      expect(opened, hasLength(1), reason: 'external link opened twice');
      pending.complete();
      pending = Completer<void>()..complete();
      await tester.pumpAndSettle();
      await tester.tap(bottom);
      await tester.pumpAndSettle();
      expect(
        opened,
        hasLength(2),
        reason: 'after first tap «Source» is locked',
      );
    },
  );

  testWidgets('release: Play plays album from track 1', (tester) async {
    final (rig, opened) = await feed(tester);

    final play = find.byKey(const Key('news-play-102'));
    await tester.scrollUntilVisible(play, 300);
    expect(find.byKey(const Key('news-source-102')), findsNothing);
    await tapAndSettle(tester, play);

    final album = sample('catalog-album')['tracks'] as List<dynamic>;
    expect(rig.played, hasLength(1));
    final (tracks, index) = rig.played.single;
    expect(index, 0);
    expect(
      [for (final track in tracks) track.id],
      [for (final row in album) (row as Map<String, dynamic>)['id']],
    );
    expect(
      rig.server.calls('GET /v1/albums/*').single.url.path,
      '/v1/albums/c1a2b3c4-0000-4000-8000-000000000001',
    );
    expect(opened, isEmpty);
  });

  testWidgets('empty feed shows hint', (tester) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/news', (_) => answer(200, {'items': const []}));
    await rig.screen(tester, (services) => NewsScreen(services: services));
    expect(find.byKey(const Key('news-empty')), findsOneWidget);
  });
}
