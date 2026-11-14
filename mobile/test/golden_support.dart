import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden master screenshots (P4): real fonts and screen dimensions for two phones.
///
/// Without [loadAppFonts], test draws rectangles instead of glyphs — screenshot
/// says nothing about layout. Fonts loaded only in test files with goldens:
/// text metrics remain untouched in other tests.
const phones = <String, Size>{'360': Size(360, 800), '412': Size(412, 915)};

Future<void> loadAppFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final file in files) {
      loader.addFont(
        File(file).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    }
    await loader.load();
  }

  await family('Onest', [
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'fonts/Onest-$weight.ttf',
  ]);
  await family('JetBrains Mono', [
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold'])
      'fonts/JetBrainsMono-$weight.ttf',
  ]);
  final sdk = Platform.environment['FLUTTER_ROOT'];
  if (sdk == null) fail('FLUTTER_ROOT не задан: значки Material не найти');
  await family('MaterialIcons', [
    '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

/// Snapshot verified strictly on Mac where taken — pixel for pixel. On Linux the
/// same fonts are rendered by a different rasterizer and different Flutter version:
/// 3–4% pixels differ (pipeline 2049, 01.10). A tolerance that wide catches nothing:
/// even 0.5% permitted cover art with 4 radius instead of 10. Therefore in
/// `mobile-tests` (Linux) golden is only rendered, while verified by `mobile-golden`
/// job on Mac runner and `scripts/check.sh` on Mac.
/// Updated Flutter on Mac — retake screenshots and visually inspect.
void compareOnMacOnly() {
  if (Platform.isMacOS) return;
  final local = goldenFileComparator as LocalFileComparator;
  goldenFileComparator = _DrawOnly(
    Uri.parse('${local.basedir}golden_test.dart'),
  );
}

class _DrawOnly extends LocalFileComparator {
  _DrawOnly(super.testFile);

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    // ignore: avoid_print
    print('$golden: не macOS — снимок нарисован, но не сверен');
    return true;
  }
}

/// Phone-sized canvas: pixel to pixel, unscaled.
void usePhone(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}
