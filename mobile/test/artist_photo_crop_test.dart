import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/catalog_screens.dart';
import 'package:music_stream/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';
import 'golden_support.dart';

/// Owner feedback 02.10 (`plan/p4-fixes.md`, E: 2, 23): artist photo
/// "eaten from top and bottom", and bottom of photo should blend into background.
///
/// Header was 250 high as in the Figma export; since FT-845 (owner 13.10: "a face does not
/// fit into the photo") it is a square of the screen width, at most 400.
/// Wikimedia photos are almost always portrait or square, while header is
/// wide: cropping is inevitable, but centered crop cuts forehead and chin. Face
/// is usually in upper part of frame, so frame is shifted upwards. Darkening at bottom
/// reaches background color without transparency — photo has no hard edge, it fades.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openArtist(WidgetTester tester) async {
    usePhone(tester, phones['360']!);
    final rig = Rig();
    final body = sample('catalog-artist-lastfm');
    (body['artist'] as Map<String, dynamic>)['photo_credit'] = 'Ann, CC0';
    rig.server.on('GET /v1/artist', (_) => answer(200, body));
    await rig.screen(
      tester,
      (services) => ArtistScreen(services: services, name: 'Metallica'),
    );
  }

  testWidgets('photo frame shifted to top, not centered', (tester) async {
    await openArtist(tester);

    final image = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const Key('artist-hero')),
        matching: find.byType(Image),
      ),
    );
    expect(image.fit, BoxFit.cover);
    final alignment = image.alignment.resolve(TextDirection.ltr);
    expect(alignment.x, 0, reason: 'width is centered');
    expect(
      alignment.y,
      lessThan(0),
      reason: 'forehead and chin get cropped if centered',
    );
  });

  testWidgets('photo is a square of the screen width, at most 400', (
    tester,
  ) async {
    await openArtist(tester);
    expect(tester.getSize(find.byKey(const Key('artist-hero'))).height, 360);

    usePhone(tester, phones['412']!);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('artist-hero'))).height, 400);
  });

  testWidgets('bottom of photo fades to bg: last color is opaque bg', (
    tester,
  ) async {
    await openArtist(tester);

    final shade = tester.widget<DecoratedBox>(
      find.byKey(const Key('artist-hero-shade')),
    );
    final gradient =
        (shade.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.end, Alignment.bottomCenter);
    expect(gradient.colors.last, ApertonoColors.background);
    // Top of photo is not covered: gradient starts nearly transparent.
    expect(gradient.colors.first.a, lessThanOrEqualTo(0.1));
  });
}
