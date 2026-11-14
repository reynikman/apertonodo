import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_playback.dart';
import 'package:music_stream/podcast_progress.dart';
import 'package:music_stream/podcast_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_server.dart';

// Lead check FT-735: episode progress synced to server and pulled from it —
// on app launch, foreground return, and backgrounding.

const feed = 'https://feeds.example.org/a.xml';

class _Box implements PodcastProgressBox {
  String? data;
  final written = <String>[];

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String value) async {
    written.add(value);
    data = value;
  }
}

/// Server that responds to page requests only when instructed by test.
class _HeldPort implements PodcastSyncPort {
  final asked = <int>[];
  final page = Completer<PodcastChanges>();

  @override
  Future<Map<String, EpisodeProgress>> put(
    Map<String, EpisodeProgress> items,
  ) async => items;

  @override
  Future<PodcastChanges> changes(int after) {
    asked.add(after);
    return asked.length == 1
        ? page.future
        : Future.value(PodcastChanges(const {}, after));
  }
}

Future<void> goBackground(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

Future<void> comeBack(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

List<String> afters(Rig rig) => [
  for (final r in rig.server.calls('GET /v1/podcasts/progress'))
    r.url.queryParameters['after']!,
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('startup: single sync from zero', (tester) async {
    final rig = Rig();
    await rig.start(tester);
    await tester.pumpAndSettle();
    expect(afters(rig), ['0']);
  });

  testWidgets('position from other device applies here', (tester) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/podcasts/progress',
      (request) => request.url.queryParameters['after'] == '0'
          ? answer(200, {
              'items': [
                {
                  'feed_url': feed,
                  'guid': 'ep-7',
                  'position_ms': 1380000,
                  'done': false,
                  'updated_at': '2026-10-10T10:00:00Z',
                },
              ],
              'mark': 7,
            })
          : answer(200, {'items': const [], 'mark': 7}),
    );
    await rig.start(tester);
    await tester.pumpAndSettle();
    // Write to disk every 5 seconds.
    await tester.pump(const Duration(seconds: 6));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefsPodcastProgressBox.key), contains('ep-7'));
    expect(prefs.getString('podcast_sync_mark'), '7');
  });

  testWidgets('resume app: sync from cursor', (tester) async {
    final rig = Rig();
    rig.server.on(
      'GET /v1/podcasts/progress',
      (_) => answer(200, {'items': const [], 'mark': 7}),
    );
    await rig.start(tester);
    await tester.pumpAndSettle();
    // Launch: initial page and check that subsequent is empty.
    expect(afters(rig), ['0', '7']);
    await goBackground(tester);
    expect(afters(rig), ['0', '7', '7']);
    await comeBack(tester);
    expect(afters(rig), ['0', '7', '7', '7']);
  });

  testWidgets('cursor is account-scoped', (tester) async {
    await PrefsPodcastMarkBox('alice').write('7');
    expect(await PrefsPodcastMarkBox('bob').read(), isNull);
    expect(await PrefsPodcastMarkBox(null).read(), isNull);
    expect(await PrefsPodcastMarkBox('alice').read(), '7');
  });

  test('device positions are account-scoped (review)', () async {
    await PrefsPodcastProgressBox('alice').write('A');
    expect(await PrefsPodcastProgressBox('bob').read(), isNull);
    expect(await PrefsPodcastProgressBox('alice').read(), 'A');
  });

  test('pre-FT-735 positions go to first account, not second', () async {
    SharedPreferences.setMockInitialValues({'podcast_progress': 'OLD'});
    expect(await PrefsPodcastProgressBox('alice').read(), 'OLD');
    expect(await PrefsPodcastProgressBox('bob').read(), isNull);
    expect(await PrefsPodcastProgressBox('alice').read(), 'OLD');
  });

  test('sync interrupted by close stops (review)', () async {
    final port = _HeldPort();
    final mark = _Box();
    final sync = PodcastSync(PodcastProgressStore(_Box()), port, mark);
    final running = sync.run();
    await Future<void>.delayed(Duration.zero);
    sync.cancel();
    port.page.complete(PodcastChanges(const {}, 5));
    expect(await running, PodcastSyncResult.stale);
    expect(port.asked, [0]);
    expect(mark.written, isEmpty, reason: 'cursor untouched: not a logout');
  });
}
