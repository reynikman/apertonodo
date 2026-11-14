import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/screens/parts.dart';

void main() {
  test('formatDuration: zero and negative is empty', () {
    expect(formatDuration(0), '');
    expect(formatDuration(-1), '');
  });

  test('formatDuration: 42 seconds', () {
    expect(formatDuration(42 * 1000), '0:42');
  });

  test('formatDuration: 3 minutes 42 seconds', () {
    expect(formatDuration((3 * 60 + 42) * 1000), '3:42');
  });

  test('formatDuration: 1 hour 5 minutes 3 seconds', () {
    expect(formatDuration((1 * 3600 + 5 * 60 + 3) * 1000), '1:05:03');
  });

  test('thousands with narrow space and Russian word', () {
    expect(
      ruCount(352844, 'исполнитель', 'исполнителя', 'исполнителей'),
      '352\u202F844 исполнителя',
    );
    expect(ruCount(21, 'жанр', 'жанра', 'жанров'), '21 жанр');
    expect(ruCount(1000, 'трек', 'трека', 'треков'), '1\u202F000 треков');
  });
}
