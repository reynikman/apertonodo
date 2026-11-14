import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Owner 02.10: "icon is still missing... not our logo". Launcher icon —
/// ours since FT-475 (checked by `scripts/icon_check.py`; APK on device, build
/// 12aca9cb, has "a" with "beta" and Apertono label). Not ours is player notification
/// icon: `AudioServiceConfig` did not set it, audio_service used
/// `mipmap/ic_launcher`, and Android renders status bar icon using only
/// alpha channel. Launcher icon has opaque background — in status bar and header
/// it produced a white square.
///
/// Dedicated icon needed: white "a" with "beta" on transparent background, 24dp.
const res = 'android/app/src/main/res';
const densities = {
  'mdpi': 1.0,
  'hdpi': 1.5,
  'xhdpi': 2.0,
  'xxhdpi': 3.0,
  'xxxhdpi': 4.0,
};

class Picture {
  Picture(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final ByteData rgba;

  Iterable<(int, int, int, int, int, int)> get pixels sync* {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        yield (
          x,
          y,
          rgba.getUint8(i),
          rgba.getUint8(i + 1),
          rgba.getUint8(i + 2),
          rgba.getUint8(i + 3),
        );
      }
    }
  }
}

Future<Picture> load(WidgetTester tester, String path) async {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'missing $path');
  final picture = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    return Picture(image.width, image.height, data!);
  });
  return picture!;
}

String read(String path) => File(path).readAsStringSync();

void main() {
  for (final MapEntry(key: density, value: scale) in densities.entries) {
    testWidgets('$density: notification icon — white on transparent', (
      tester,
    ) async {
      final path = '$res/drawable-$density/ic_stat_apertono.png';
      final icon = await load(tester, path);
      final side = (24 * scale).round();
      expect((icon.width, icon.height), (side, side), reason: path);
      final drawn = icon.pixels.where((p) => p.$6 >= 16).toList();
      expect(drawn, isNotEmpty, reason: '$path: empty');
      // Symbol, not solid badge: "a" with "beta" circle occupies less than half
      // the square. Almost fully filled would become a white square in status bar again.
      expect(
        drawn.length,
        lessThan(side * side * 0.6),
        reason: '$path: mostly filled — status bar would show white square',
      );
      expect(
        drawn.length,
        greaterThan(side * side * 0.15),
        reason: '$path: glyph is too small',
      );
      for (final (x, y, r, g, b, _) in drawn) {
        expect(
          r >= 235 && g >= 235 && b >= 235,
          isTrue,
          reason: '$path: ($x, $y) not white — Android tints only alpha',
        );
      }
      // "beta" is cutout inside circle, not filled: otherwise status bar shows blob instead of "a beta".
      // Cutout exists if inside image transparent pixels are surrounded by
      // opaque pixels along the scanline.
      final rows = <int, List<int>>{};
      for (final (x, y, _, _, _, _) in drawn) {
        rows.putIfAbsent(y, () => []).add(x);
      }
      final holes = rows.values.where((xs) {
        xs.sort();
        for (var i = 1; i < xs.length; i++) {
          if (xs[i] - xs[i - 1] > 1) return true;
        }
        return false;
      });
      expect(holes, isNotEmpty, reason: '$path: glyph lacks cutouts — blob');
    });
  }

  test('player sets notification icon, build will not strip it', () {
    expect(
      read('lib/main.dart'),
      contains("androidNotificationIcon: 'drawable/ic_stat_apertono'"),
    );
    // audio_service looks up icon by name (getIdentifier): release build with
    // resource shrinking without keep would strip the file and notification would crash.
    expect(read('$res/raw/keep.xml'), contains('@drawable/ic_stat_apertono'));
  });
}
