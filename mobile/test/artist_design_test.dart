import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// Artist by Figma export (P4, step 6; handoff §6.4, frame `crop_phone4_artist`):
/// full-width square photo (FT-845, was 250 high) below status bar, circular "back" arrow
/// on top, name large on photo, author attribution on the right; "Play" —
/// pill with gold circle; "Popular" — five tracks with duration, "More"
/// expands to ten (P-A51, `artist_rows_test.dart`); "Albums" — horizontal strip. No heart or "⋮" for artist: favorite
/// artists are not stored on server (P-A29). Similar artists and biography — below, as before.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final hero = find.byKey(const Key('artist-hero'));
  final back = find.byKey(const Key('artist-back'));
  final name = find.byKey(const Key('artist-name'));
  final play = find.byKey(const Key('artist-play'));
  final more = find.byKey(const Key('popular-more'));
  Finder row(int index) => find.byKey(Key('top-track-$index'));

  /// Five numbered tracks (play immediately) and three albums.
  Map<String, dynamic> page({bool photo = true}) {
    final body = sample('catalog-artist-lastfm');
    final song = (body['top_tracks'] as List).first as Map<String, dynamic>;
    body['top_tracks'] = [
      for (final (i, title) in [
        'Enter Sandman',
        'One',
        'Master of Puppets',
        'Fade to Black',
        'Battery',
      ].indexed)
        {
          ...song,
          'id': '00000000-0000-4000-8000-00000000000${i + 1}',
          'title': title,
          'duration_ms': (5 * 60 + 31 + i) * 1000,
        },
    ];
    final album = (body['albums'] as List).first as Map<String, dynamic>;
    body['albums'] = [
      for (final (i, title) in ['Metallica', 'Load', 'Reload'].indexed)
        {
          ...album,
          'id': 'e8f70201-8899-3f0c-9e07-5d6495bc804$i',
          'title': title,
          'year': 1991 + i * 5,
        },
    ];
    // Short attribution: in tests Ahem font glyphs are square, long text will be clipped
    // by width, making it unclear which edge it is aligned to.
    (body['artist'] as Map<String, dynamic>)['photo_credit'] = 'Ann, CC0';
    if (!photo) {
      (body['artist'] as Map<String, dynamic>)
        ..remove('photo')
        ..remove('photo_credit');
    }
    return body;
  }

  Future<Rig> openArtist(
    WidgetTester tester, {
    bool photo = true,
    Size? size,
  }) async {
    usePhone(tester, size ?? phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/artist', (_) => answer(200, page(photo: photo)));
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );
    return rig;
  }

  testWidgets('full-width square photo below notification bar; no AppBar', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 36);
    addTearDown(tester.view.resetPadding);
    await openArtist(tester);

    expect(find.byType(AppBar), findsNothing);
    final rect = tester.getRect(hero);
    expect(rect.top, 0);
    expect(rect.left, 0);
    expect(rect.right, 360);
    // FT-845, owner 13.10: a 250-high strip cut faces off portrait photos.
    expect(rect.height, 360);
    // Darkening downwards — otherwise white name gets lost on light photo.
    final shade = tester.widget<DecoratedBox>(
      find.byKey(const Key('artist-hero-shade')),
    );
    final gradient = (shade.decoration as BoxDecoration).gradient!;
    expect(gradient, isA<LinearGradient>());
    expect(gradient.colors.last.a, greaterThan(gradient.colors.first.a));
  });

  testWidgets('back arrow — circle 40 with blur, under the status bar', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 36);
    addTearDown(tester.view.resetPadding);
    await openArtist(tester);

    final rect = tester.getRect(back);
    expect(rect.size, const Size(40, 40));
    expect(rect.left, 16);
    expect(rect.top, greaterThanOrEqualTo(36 + 4));
    // Circle is blurred, as in Figma export: filter 8, enabled.
    final blur = tester.widget<BackdropFilter>(
      find.descendant(of: back, matching: find.byType(BackdropFilter)),
    );
    expect(blur.enabled, isTrue);
    expect(blur.filter, ImageFilter.blur(sigmaX: 8, sigmaY: 8));
    // Inside is a regular BackButton: TalkBack and tests find "back" by it
    // (`tester.pageBack()`).
    expect(
      find.descendant(of: back, matching: find.byType(BackButton)),
      findsOneWidget,
    );
    // No heart or "⋮": server does not store favorite artists (P-A29).
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });

  testWidgets('back arrow returns to previous screen', (tester) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/artist', (_) => answer(200, page()));
    await rig.screen(
      tester,
      (services) => Builder(
        builder: (context) => TextButton(
          key: const Key('open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  ArtistScreen(services: services, name: 'Metallica'),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tapAndSettle(tester, find.byKey(const Key('open')));
    expect(find.byType(ArtistScreen), findsOneWidget);
    await tapAndSettle(tester, back);
    expect(find.byType(ArtistScreen), findsNothing);
  });

  testWidgets('name large on photo, author credit on photo right', (
    tester,
  ) async {
    await openArtist(tester);

    final text = tester.widget<Text>(name);
    expect(text.data, 'Metallica');
    expect(text.style?.fontSize, 34);
    expect(text.style?.fontWeight, FontWeight.w700);
    final photo = tester.getRect(hero);
    final nameRect = tester.getRect(name);
    expect(nameRect.left, 16);
    expect(nameRect.bottom, lessThanOrEqualTo(photo.bottom));
    expect(nameRect.top, greaterThan(photo.center.dy));

    final credit = find.text('фото: Ann, CC0');
    expect(credit, findsOneWidget);
    final creditRect = tester.getRect(credit);
    // Where the text itself is painted, not its bounding box: box can be full width.
    final paragraph = tester.renderObject<RenderParagraph>(credit);
    final glyphs = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 'фото: Ann, CC0'.length),
    );
    final paintedRight = creditRect.left + glyphs.last.right;
    expect(paintedRight, moreOrLessEquals(360 - 16, epsilon: 1));
    expect(creditRect.bottom, lessThanOrEqualTo(photo.bottom));
    expect(creditRect.top, greaterThanOrEqualTo(nameRect.bottom - 0.5));
    expect(tester.widget<Text>(credit).style?.fontSize, 11);
  });

  testWidgets('Play is 52 pill with gold circle and plays top songs', (
    tester,
  ) async {
    final rig = await openArtist(tester);

    final rect = tester.getRect(play);
    expect(rect.height, 52);
    expect(rect.left, 16);
    expect(rect.top, greaterThanOrEqualTo(tester.getRect(hero).bottom + 8));
    final pill = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: play,
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .first,
    );
    final box = pill.decoration as BoxDecoration;
    expect(box.borderRadius, BorderRadius.circular(26));
    expect(box.color, ApertonoColors.surface);
    expect((box.border as Border?)?.top.color, ApertonoColors.border);
    final circle = find.byKey(const Key('artist-play-circle'));
    expect(tester.getSize(circle), const Size(40, 40));
    final circleBox =
        tester.widget<DecoratedBox>(circle).decoration as BoxDecoration;
    expect(circleBox.color, ApertonoColors.accent);
    expect(circleBox.shape, BoxShape.circle);
    final label = tester.widget<Text>(
      find.descendant(of: play, matching: find.text('Слушать')),
    );
    expect(label.style?.fontSize, 16);
    expect(label.style?.fontWeight, FontWeight.w600);

    await tapAndSettle(tester, play);
    expect(rig.played, hasLength(1));
    final (queue, start) = rig.played.single;
    expect(start, 0);
    expect(queue.map((track) => track.title).toList(), [
      'Enter Sandman',
      'One',
      'Master of Puppets',
      'Fade to Black',
      'Battery',
    ]);
  });

  testWidgets('no Play button if none of the songs has track number', (
    tester,
  ) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    rig.server.on('GET /v1/artist', (_) {
      final body = page();
      body['top_tracks'] = [
        {'title': 'Enter Sandman', 'playable': true},
      ];
      return answer(200, body);
    });
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );
    expect(play, findsNothing);
    expect(find.text('Enter Sandman'), findsOneWidget);
  });

  testWidgets('Popular: five songs with cover 56, title, duration', (
    tester,
  ) async {
    await openArtist(tester);

    final heading = find.widgetWithText(Heading, 'Популярное');
    expect(heading, findsOneWidget);
    expect(find.text('Популярные песни'), findsNothing);
    expect(
      tester.getRect(heading).top,
      greaterThan(tester.getRect(play).bottom),
    );
    expect(row(0), findsOneWidget);
    expect(row(4), findsOneWidget);
    expect(row(5), findsNothing);

    final first = row(0);
    expect(
      tester.getSize(find.descendant(of: first, matching: find.byType(Cover))),
      const Size(56, 56),
    );
    final title = tester.widget<Text>(
      find.descendant(of: first, matching: find.text('Enter Sandman')),
    );
    expect(title.style?.fontSize, ApertonoText.trackTitle.fontSize);
    final time = find.descendant(of: first, matching: find.text('5:31'));
    expect(time, findsOneWidget);
    expect(
      tester.widget<Text>(time).style?.color,
      ApertonoColors.textSecondary,
    );
    expect(
      tester.getRect(time).left,
      greaterThan(
        tester
            .getRect(
              find.descendant(of: first, matching: find.text('Enter Sandman')),
            )
            .right,
      ),
    );
    expect(tester.getRect(time).right, lessThanOrEqualTo(360 - 16 + 0.01));
    // Rows stacked under each other, without arbitrary gaps: each at least 64 high.
    expect(tester.getRect(row(1)).top, tester.getRect(row(0)).bottom);
    expect(tester.getSize(row(0)).height, greaterThanOrEqualTo(64));
  });

  testWidgets('five songs: no More button, nothing to expand (R-A51)', (
    tester,
  ) async {
    await openArtist(tester);

    expect(more, findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.text('Battery'), findsOneWidget);
  });

  testWidgets('song from Popular plays from it, queue is all top songs', (
    tester,
  ) async {
    final rig = await openArtist(tester);

    await tapAndSettle(tester, row(1));
    final (queue, start) = rig.played.single;
    expect(queue[start].title, 'One');
    expect(queue, hasLength(5));
  });

  testWidgets('Albums: below Popular, horizontal scroll, cover 132', (
    tester,
  ) async {
    await openArtist(tester);

    final heading = find.widgetWithText(Heading, 'Альбомы');
    expect(
      tester.getRect(heading).top,
      greaterThan(tester.getRect(row(2)).bottom - 0.01),
    );
    final first = find.byKey(
      const ValueKey('album-tile-e8f70201-8899-3f0c-9e07-5d6495bc8040'),
    );
    final second = find.byKey(
      const ValueKey('album-tile-e8f70201-8899-3f0c-9e07-5d6495bc8041'),
    );
    // Scroll page downwards, not strip horizontally: otherwise 16 padding drifts.
    await tester.ensureVisible(find.byKey(const Key('artist-albums')));
    await tester.pumpAndSettle();
    expect(tester.getRect(first).left, 16);
    expect(tester.getRect(second).top, tester.getRect(first).top);
    expect(
      tester.getRect(second).left,
      moreOrLessEquals(tester.getRect(first).right + 12, epsilon: 0.5),
    );
    expect(
      tester.getSize(find.descendant(of: first, matching: find.byType(Cover))),
      const Size(132, 132),
    );
    expect(
      find.ancestor(
        of: first,
        matching: find.byKey(const Key('artist-albums')),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('artist-albums')))
          .scrollDirection,
      Axis.horizontal,
    );
  });

  testWidgets('similar and bio: below albums as before', (tester) async {
    await openArtist(tester);

    final albums = find.widgetWithText(Heading, 'Альбомы');
    for (final text in ['Похожие исполнители', 'Об исполнителе']) {
      final heading = find.widgetWithText(Heading, text);
      expect(heading, findsOneWidget, reason: text);
      expect(
        tester.getRect(heading).top,
        greaterThan(tester.getRect(albums).top),
        reason: text,
      );
    }
  });

  testWidgets('no photo: no banner, arrow and name as heading below', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 36);
    addTearDown(tester.view.resetPadding);
    await openArtist(tester, photo: false);

    expect(hero, findsNothing);
    expect(find.textContaining('фото:'), findsNothing);
    expect(back, findsOneWidget);
    expect(tester.getRect(back).top, greaterThanOrEqualTo(36 + 4));
    final rect = tester.getRect(name);
    expect(rect.top, greaterThan(tester.getRect(back).bottom));
    expect(rect.left, 16);
    expect(play, findsOneWidget);
    expect(tester.getRect(play).top, greaterThan(rect.bottom));
  });

  testWidgets('large font: nothing overflows layout', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openArtist(tester);
    expect(tester.takeException(), isNull);
    await openArtist(tester, photo: false);
    expect(tester.takeException(), isNull);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: label, value: size) in phones.entries) {
      testWidgets('artist at $label dp', (tester) async {
        // Across the whole app: theme and fonts match the real phone.
        usePhone(tester, size);
        final rig = Rig();
        rig.server.on('GET /v1/artist', (_) => answer(200, page()));
        await rig.start(tester);
        await tester.pumpAndSettle();
        await typeSearch(tester, 'metallica');
        await tapAndSettle(tester, find.byKey(const Key('artist-Metallica')));
        expect(find.byType(ArtistScreen), findsOneWidget);
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile('goldens/artist_$label.png'),
        );
      });
    }
  });
}
