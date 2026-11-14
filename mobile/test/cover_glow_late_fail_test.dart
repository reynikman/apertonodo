// Lead check FT-564: cover art that failed to finish loading does not crash
// app or phone tests.
//
// `device-negative-control` failed after test ended: HttpException
// "No content even though contentLength…" behind cover art. Glow color
// (`ColorScheme.fromImageProvider`) cancels its listener after 5 s,
// and late image error leaks into unhandled FlutterError.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/cover_glow.dart';

/// Image that fails after [after] — like a dropped server response.
class LateFail extends ImageProvider<LateFail> {
  const LateFail(this.after);

  final Duration after;

  @override
  Future<LateFail> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(LateFail key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: Future<ui.Codec>.delayed(
          after,
          () => throw const HttpException(
            'No content even though contentLength was specified',
          ),
        ),
        scale: 1,
      );
}

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  for (final after in const [
    Duration(milliseconds: 100),
    Duration(seconds: 8),
  ]) {
    testWidgets('cover failure after ${after.inMilliseconds} ms is quiet', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CoverGlow(
            image: LateFail(after),
            size: 100,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 6));
      // Screen popped before failure arrived.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
      expect(find.byKey(CoverGlow.glowKey), findsNothing);
    });
  }
}
