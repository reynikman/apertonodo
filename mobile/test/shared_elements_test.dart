import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/models/track.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// Shared screen elements per dump (P4, step 1; FT-469): track row,
/// section header, cover art and placeholder, chips, empty/error banner.
///
/// Values from owner `flowtune-design-system.html`: row `min-height 56`,
/// padding 8, cover 46 with radius 10, gap 12; chip with radius 16
/// (height enforced by golden test: varies with real typography vs test font).
const _numb = Track(
  id: 'numb',
  title: 'Numb',
  artist: 'Linkin Park',
  durationMs: 187000,
  artworkUrl: '',
);
const _long = Track(
  id: 'long',
  title: 'Очень длинное название песни, которое не влезает в одну строку',
  artist: 'Исполнитель с длинным именем и ещё одним словом',
  durationMs: 354000,
  artworkUrl: '',
);
const _pale = Track(
  id: 'pale',
  title: 'Ёжик в тумане',
  artist: 'Queen',
  durationMs: 0,
  artworkUrl: '',
  playable: false,
);

void main() {
  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.text(text)).text.style!;

  Future<Services> pump(
    WidgetTester tester,
    Widget Function(Services services) build,
  ) async {
    final server = FakeServer();
    final services = Services(
      server: server.api(),
      search: server.catalog().search,
      play: (_, _) {},
      prepare: (_) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        home: Scaffold(body: build(services)),
      ),
    );
    await tester.pumpAndSettle();
    return services;
  }

  testWidgets('section heading: 18 bold, white, not amber', (tester) async {
    await pump(tester, (_) => const Heading('Популярное'));
    final style = styleOf(tester, 'Популярное');
    expect(style.fontFamily, 'Onest');
    expect(style.fontSize, 18);
    expect(style.fontWeight, FontWeight.w700);
    expect(style.color, ApertonoColors.textPrimary);
  });

  testWidgets('song row: layout typography, single line per field', (
    tester,
  ) async {
    await pump(
      tester,
      (_) => Column(
        children: [
          TrackTile(track: _numb, onTap: () {}),
          TrackTile(track: _long, onTap: () {}),
        ],
      ),
    );
    final title = styleOf(tester, 'Numb');
    expect(title.fontFamily, 'Onest');
    expect(title.fontSize, 15);
    expect(title.fontWeight, FontWeight.w600);
    expect(title.color, ApertonoColors.textPrimary);

    final artist = styleOf(tester, 'Linkin Park · 3:07');
    expect(artist.fontSize, 12.5);
    expect(artist.fontWeight, FontWeight.w400);
    expect(artist.color, ApertonoColors.textSecondary);

    // Without cover row is exactly min 56, long title does not expand it.
    final rows = find.byType(TrackTile);
    expect(tester.getSize(rows.at(0)).height, 56);
    expect(tester.getSize(rows.at(1)).height, 56);
    expect(tester.takeException(), isNull);
  });

  testWidgets('row with cover: 46 with radius 10, gap 12, height 62', (
    tester,
  ) async {
    late Hearts hearts;
    final services = await pump(tester, (services) {
      hearts = Hearts(services.server)..show([_numb, _long]);
      return Column(
        children: [
          TrackTile(
            track: _numb,
            onTap: () {},
            services: services,
            oneTap: true,
          ),
          TrackTile(
            track: _long,
            onTap: () {},
            services: services,
            hearts: hearts,
            oneTap: true,
          ),
        ],
      );
    });
    addTearDown(hearts.dispose);
    expect(services, isNotNull);

    final rows = find.byType(TrackTile);
    final cover = find.descendant(of: rows.at(0), matching: find.byType(Cover));
    expect(tester.getSize(cover), const Size(46, 46));
    expect(tester.getTopLeft(cover).dx, 16);
    expect(tester.getTopLeft(find.text('Numb')).dx, 16 + 46 + 12);
    expect(tester.getSize(rows.at(0)).height, 62);

    // Heart and menu have 48 touch targets without increasing row height.
    expect(tester.getSize(rows.at(1)).height, 62);
    final heart = find.byKey(const ValueKey('heart-long'));
    expect(tester.getSize(heart).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(heart).width, greaterThanOrEqualTo(48));

    // Unselected heart is gray like other icons; amber only when
    // favorited. Otherwise list of twenty songs shows twenty visual accents.
    Color? iconColor(Finder button) => tester
        .widget<RichText>(
          find.descendant(of: button, matching: find.byType(RichText)),
        )
        .text
        .style
        ?.color;
    expect(iconColor(heart), ApertonoColors.textSecondary);
    await tester.tap(heart);
    await tester.pumpAndSettle();
    expect(iconColor(heart), ApertonoColors.accent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large font: row grows, does not clip text', (tester) async {
    late Hearts hearts;
    await pump(tester, (services) {
      hearts = Hearts(services.server)..show([_long]);
      return Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: Column(
            children: [
              TrackTile(track: _numb, onTap: () {}),
              TrackTile(
                track: _long,
                onTap: () {},
                services: services,
                hearts: hearts,
                oneTap: true,
              ),
            ],
          ),
        ),
      );
    });
    addTearDown(hearts.dispose);
    expect(tester.takeException(), isNull, reason: 'text did not fit line');
    final rows = find.byType(TrackTile);
    expect(tester.getSize(rows.at(0)).height, greaterThan(56));
    expect(tester.getSize(rows.at(1)).height, greaterThan(62));
  });

  testWidgets('unplayable track is dim but tappable', (tester) async {
    var taps = 0;
    await pump(tester, (_) => TrackTile(track: _pale, onTap: () => taps++));
    expect(
      styleOf(tester, 'Ёжик в тумане').color,
      isNot(ApertonoColors.textPrimary),
    );
    await tester.tap(find.text('Ёжик в тумане'));
    expect(taps, 1);
  });

  testWidgets('cover and placeholder rounded: 10 default, 12 album', (
    tester,
  ) async {
    BorderRadiusGeometry clip(Finder of) => tester
        .widget<ClipRRect>(
          find.descendant(of: of, matching: find.byType(ClipRRect)).first,
        )
        .borderRadius;

    await pump(
      tester,
      (services) => Column(
        children: [
          const ArtistSquare('Linkin Park', size: 46),
          Cover(server: services.server, path: null, artist: 'Queen'),
          Cover(
            server: services.server,
            path: '/v1/covers/album-1',
            artist: 'Slipknot',
            size: 104,
            radius: ApertonoRadii.album,
          ),
        ],
      ),
    );
    expect(
      clip(find.byType(ArtistSquare).first),
      BorderRadius.circular(ApertonoRadii.cover),
    );
    final covers = find.byType(Cover);
    expect(clip(covers.at(0)), BorderRadius.circular(ApertonoRadii.cover));
    expect(clip(covers.at(1)), BorderRadius.circular(ApertonoRadii.album));
    expect(tester.getSize(covers.at(1)), const Size(104, 104));
  });

  testWidgets('chip: radius 16, gray text on bordered tile', (tester) async {
    await pump(
      tester,
      (_) => Center(
        child: ActionChip(label: const Text('Radiohead'), onPressed: () {}),
      ),
    );
    final theme = apertonoTheme().chipTheme;
    expect(theme.backgroundColor, ApertonoColors.surface);
    expect(theme.side?.color, ApertonoColors.border);
    expect(
      theme.shape,
      isA<RoundedRectangleBorder>().having(
        (shape) => shape.borderRadius,
        'borderRadius',
        BorderRadius.circular(16),
      ),
    );
    final label = styleOf(tester, 'Radiohead');
    expect(label.fontSize, 13);
    expect(label.fontWeight, FontWeight.w500);
    expect(label.color, ApertonoColors.textSecondary);
  });

  testWidgets('message: layout text and "Retry" present', (tester) async {
    var retried = 0;
    await pump(
      tester,
      (_) => Message('Сервер не ответил', onRetry: () => retried++),
    );
    final style = styleOf(tester, 'Сервер не ответил');
    expect(style.fontSize, 15);
    expect(style.fontWeight, FontWeight.w600);
    expect(style.color, ApertonoColors.textPrimary);
    await tester.tap(find.text('Повторить'));
    expect(retried, 1);
  });

  group('снимок-эталон', () {
    setUpAll(() async {
      await loadAppFonts();
      compareOnMacOnly();
    });

    for (final MapEntry(key: name, value: size) in phones.entries) {
      testWidgets('shared elements on $name dp', (tester) async {
        usePhone(tester, size);
        late Hearts hearts;
        await pump(tester, (services) {
          hearts = Hearts(services.server)..show([_numb, _long, _pale]);
          return SafeArea(
            child: ListView(
              children: [
                const Heading('Популярное'),
                for (final track in [_numb, _long, _pale])
                  TrackTile(
                    track: track,
                    onTap: () {},
                    services: services,
                    hearts: hearts,
                    oneTap: true,
                  ),
                const Heading('Без обложки и кнопок'),
                TrackTile(track: _numb, onTap: () {}),
                const Heading('Подсказки'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final name in ['Radiohead', 'Queen', 'Кино'])
                        ActionChip(label: Text(name), onPressed: () {}),
                    ],
                  ),
                ),
                const Heading('Альбом'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Cover(
                      server: services.server,
                      path: null,
                      artist: 'Linkin Park',
                      size: 104,
                      radius: ApertonoRadii.album,
                    ),
                  ),
                ),
                SizedBox(
                  height: 180,
                  child: Message('Сервер не ответил', onRetry: () {}),
                ),
              ],
            ),
          );
        });
        addTearDown(hearts.dispose);
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/shared_elements_$name.png'),
        );
      });
    }
  });
}
