import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the app sends only GET and POST — NPM cuts the rest', () {
    // NPM sits before server on production host, passing only
    // GET, HEAD, and POST: PUT, PATCH, and DELETE are rejected with 405 (Phase H,
    // docs/troubleshooting.md item 27). Screen tests would miss this — they
    // target mock server directly rather than proxy. Backend counterpart is
    // guarded by `test_every_route_uses_only_get_and_post`.
    final source = File('lib/server_api.dart').readAsStringSync();
    final methods = {
      for (final call in RegExp(r"_call\(\s*'([A-Z]+)'").allMatches(source))
        call[1]!,
    };
    expect(methods, {'GET', 'POST'});
  });

  test('sample responses stored in single shared contracts/', () {
    // Copies in `test/contracts/` were necessary until backend phases F, F2, H
    // merged into `main` and sample fixtures were missing. Phases are merged, but copies
    // diverged on first response change (Phase K, 20.09.2026):
    // screens verified against outdated fixtures unnoticed. New copy
    // is the same trap, which is why it is omitted here.
    expect(
      Directory('test/contracts').existsSync(),
      isFalse,
      reason: 'samples taken from shared contracts/, no duplicate copy',
    );
    expect(Directory('../contracts').listSync().whereType<File>(), isNotEmpty);
  });
}
