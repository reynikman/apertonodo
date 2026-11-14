import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/env.dart';

void main() {
  test('compiled env keys stay public', () {
    // The app has no shared key since FT-047/FT-049; the list is what is safe
    // to show in full.
    expect(
      AppEnv.keys,
      unorderedEquals(['MUSIC_ENV', 'MUSIC_API_BASE_URL', 'MUSIC_HEALTH_PATH']),
    );
    expect(AppEnv.keys, isNot(contains('MUSIC_API_KEY')));
    expect(AppEnv.apiBaseUrl.startsWith('http'), isTrue);
  });
}
