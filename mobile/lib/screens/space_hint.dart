import 'package:flutter/material.dart';

const int avgFlacBytes = 30 * 1024 * 1024;
const int avgOpusBytes = 4 * 1024 * 1024;

int roughCount(int n) {
  if (n < 100) return n;
  var factor = 1;
  var temp = n;
  while (temp >= 100) {
    factor *= 10;
    temp ~/= 10;
  }
  return ((n + factor ~/ 2) ~/ factor) * factor;
}

class SpaceHintTexts {
  const SpaceHintTexts({required this.fits, required this.nothing});

  final String Function(int flac, int opus) fits;
  final String nothing;
}

String spaceHint(int bytes, SpaceHintTexts texts) {
  if (bytes < avgOpusBytes) {
    return texts.nothing;
  }
  final flac = roughCount(bytes ~/ avgFlacBytes);
  final opus = roughCount(bytes ~/ avgOpusBytes);
  return texts.fits(flac, opus);
}

class SpaceHint extends StatelessWidget {
  const SpaceHint({super.key, required this.bytes, required this.texts});

  final int bytes;
  final SpaceHintTexts texts;

  @override
  Widget build(BuildContext context) {
    return Text(spaceHint(bytes, texts));
  }
}
