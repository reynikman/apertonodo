import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/player.dart';
import 'package:music_stream/screens/cover_glow.dart';
import 'package:music_stream/screens/parts.dart';
import 'package:music_stream/theme.dart';

/// 16×16 opaque red PNG: cover art from which glow extracts color.
final redPng = Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x00,
  0x10,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x91,
  0x68,
  0x36,
  0x00,
  0x00,
  0x00,
  0x16,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0xda,
  0x63,
  0xf8,
  0xcf,
  0xc0,
  0x40,
  0x12,
  0x62,
  0x18,
  0xd5,
  0x30,
  0xaa,
  0x61,
  0xf8,
  0x6a,
  0x00,
  0x00,
  0x90,
  0xf9,
  0xff,
  0x01,
  0xf2,
  0xee,
  0xe8,
  0x57,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
]);

void main() {
  testWidgets('no cover, no glow', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        home: const Scaffold(
          body: CoverGlow(
            child: SizedBox(key: Key('cover'), width: 80, height: 80),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('cover')), findsOneWidget);
    expect(find.byKey(CoverGlow.glowKey), findsNothing);
  });

  testWidgets('glow takes cover color, player button stays amber', (
    tester,
  ) async {
    const fromCover = Color(0xFFCC2020);
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        home: Scaffold(
          body: Column(
            children: [
              CoverGlow(
                image: MemoryImage(redPng),
                size: 80,
                readColor: (_) async => fromCover,
                child: const SizedBox(width: 80, height: 80),
              ),
              PlayPauseButton(player: Player()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final glow = tester.widget<DecoratedBox>(find.byKey(CoverGlow.glowKey));
    final color = (glow.decoration as BoxDecoration).boxShadow!.first.color;
    expect(color.withValues(alpha: 1), fromCover);
    expect(color.withValues(alpha: 1), isNot(const Color(0xFFE5A93B)));

    final context = tester.element(find.byType(IconButton));
    final foreground = IconButtonTheme.of(
      context,
    ).style?.foregroundColor?.resolve({});
    expect(foreground, const Color(0xFFE5A93B));
    expect(Theme.of(context).colorScheme.primary, const Color(0xFFE5A93B));
  });

  testWidgets('glow draws around but takes no more room than the cover', (
    tester,
  ) async {
    // On phone, glow with 2.2x cover width took up layout space:
    // above and below cover was half-screen of blank space, buttons moved down.
    await tester.pumpWidget(
      MaterialApp(
        theme: apertonoTheme(),
        home: Scaffold(
          body: Center(
            child: CoverGlow(
              image: MemoryImage(redPng),
              size: 80,
              readColor: (_) async => const Color(0xFFCC2020),
              child: const SizedBox(width: 80, height: 80),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(CoverGlow.glowKey), findsOneWidget);
    expect(tester.getSize(find.byType(CoverGlow)), const Size(80, 80));
  });

  testWidgets('from red cover color is not amber', (tester) async {
    Color? swatch;
    await tester.runAsync(() async {
      swatch = await colorFromCover(MemoryImage(redPng));
    });
    expect(swatch, isNotNull);
    final color = swatch!;
    expect(color.r, greaterThan(color.g));
    expect(color.r, greaterThan(color.b));
    expect(color.withValues(alpha: 1), isNot(const Color(0xFFE5A93B)));
  });
}
