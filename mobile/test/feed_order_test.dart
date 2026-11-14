import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/feed_order.dart';

// Lead check FT-707 (Pd-2, app). Executor does not modify this file.
//
// Disk format contract: JSON {"feeds": {"<feedUrl>": "oldest", ...}};
// "newest first" is default and not written to disk.

class MemoryBox implements FeedOrderBox {
  MemoryBox([this.data]);
  String? data;
  int writes = 0;
  bool failRead = false;
  bool failWrite = false;

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('disk');
    return data;
  }

  @override
  Future<void> write(String value) async {
    if (failWrite) throw StateError('disk');
    writes++;
    data = value;
  }

  Map<String, dynamic> get feeds =>
      (jsonDecode(data!) as Map<String, dynamic>)['feeds']
          as Map<String, dynamic>;
}

const a = 'https://a.example/rss';
const b = 'https://b.example/rss';

void main() {
  test('default order is newest first', () {
    final store = FeedOrderStore(MemoryBox());
    expect(store.orderOf(a), FeedOrder.newestFirst);
  });

  test('order is set per podcast, other podcasts unaffected', () async {
    final store = FeedOrderStore(MemoryBox());
    await store.restore();
    await store.set(a, FeedOrder.oldestFirst);
    expect(store.orderOf(a), FeedOrder.oldestFirst);
    expect(store.orderOf(b), FeedOrder.newestFirst);
  });

  test('order persists across restarts', () async {
    final box = MemoryBox();
    final first = FeedOrderStore(box);
    await first.restore();
    await first.set(a, FeedOrder.oldestFirst);
    final again = FeedOrderStore(box);
    await again.restore();
    expect(again.orderOf(a), FeedOrder.oldestFirst);
    expect(again.orderOf(b), FeedOrder.newestFirst);
  });

  test(
    'disk format: only oldest stored, default value is not written',
    () async {
      final box = MemoryBox();
      final store = FeedOrderStore(box);
      await store.restore();
      await store.set(a, FeedOrder.oldestFirst);
      await store.set(b, FeedOrder.newestFirst);
      expect(box.feeds, {a: 'oldest'});
      await store.set(a, FeedOrder.newestFirst);
      expect(box.feeds, isEmpty);
    },
  );

  test('reading format from disk', () async {
    final store = FeedOrderStore(
      MemoryBox(
        jsonEncode({
          'feeds': {a: 'oldest', b: 'newest'},
        }),
      ),
    );
    await store.restore();
    expect(store.orderOf(a), FeedOrder.oldestFirst);
    expect(store.orderOf(b), FeedOrder.newestFirst);
  });

  test('unknown value uses default, remaining entries preserved', () async {
    final store = FeedOrderStore(
      MemoryBox(
        jsonEncode({
          'feeds': {a: 'sideways', b: 'oldest', 'c': 7},
        }),
      ),
    );
    await store.restore();
    expect(store.orderOf(a), FeedOrder.newestFirst);
    expect(store.orderOf(b), FeedOrder.oldestFirst);
    expect(store.orderOf('c'), FeedOrder.newestFirst);
  });

  for (final broken in [
    '',
    'not json',
    '[1,2]',
    '{"feeds": 5}',
    'null',
    '{"feeds": [1]}',
  ]) {
    test('corrupted data $broken does not crash launch', () async {
      final store = FeedOrderStore(MemoryBox(broken));
      await store.restore();
      expect(store.orderOf(a), FeedOrder.newestFirst);
      await store.set(a, FeedOrder.oldestFirst);
      expect(store.orderOf(a), FeedOrder.oldestFirst);
    });
  }

  test('empty disk and read error do not crash launch', () async {
    final empty = FeedOrderStore(MemoryBox());
    await empty.restore();
    expect(empty.orderOf(a), FeedOrder.newestFirst);
    final box = MemoryBox()..failRead = true;
    final failing = FeedOrderStore(box);
    await failing.restore();
    expect(failing.orderOf(a), FeedOrder.newestFirst);
  });

  test('write error does not crash set, choice stays in memory', () async {
    final box = MemoryBox()..failWrite = true;
    final store = FeedOrderStore(box);
    await store.restore();
    await store.set(a, FeedOrder.oldestFirst);
    expect(store.orderOf(a), FeedOrder.oldestFirst);
  });

  test('choice made before restore is not overwritten by disk', () async {
    final box = MemoryBox(
      jsonEncode({
        'feeds': {a: 'oldest', b: 'oldest'},
      }),
    );
    final store = FeedOrderStore(box);
    await store.set(a, FeedOrder.newestFirst);
    await store.restore();
    expect(store.orderOf(a), FeedOrder.newestFirst);
    expect(store.orderOf(b), FeedOrder.oldestFirst);
    // disk is untouched before restore, merged choices on disk after
    expect(box.feeds, {b: 'oldest'});
  });

  test('listeners notified of change, not of duplicate value', () async {
    final store = FeedOrderStore(MemoryBox());
    await store.restore();
    var calls = 0;
    store.addListener(() => calls++);
    await store.set(a, FeedOrder.oldestFirst);
    expect(calls, 1);
    await store.set(a, FeedOrder.oldestFirst);
    expect(calls, 1);
    await store.set(a, FeedOrder.newestFirst);
    expect(calls, 2);
  });

  test('at most 2000 podcasts: oldest entries evicted', () async {
    expect(FeedOrderStore.maxFeeds, 2000);
    final box = MemoryBox();
    final store = FeedOrderStore(box);
    await store.restore();
    for (var i = 0; i < 2005; i++) {
      await store.set('f$i', FeedOrder.oldestFirst);
    }
    expect(box.feeds.length, 2000);
    expect(store.orderOf('f0'), FeedOrder.newestFirst);
    expect(store.orderOf('f4'), FeedOrder.newestFirst);
    expect(store.orderOf('f5'), FeedOrder.oldestFirst);
    expect(store.orderOf('f2004'), FeedOrder.oldestFirst);
  });

  test('reselecting refreshes entry so it is not evicted first', () async {
    final store = FeedOrderStore(MemoryBox());
    await store.restore();
    for (var i = 0; i < 2000; i++) {
      await store.set('f$i', FeedOrder.oldestFirst);
    }
    await store.set('f0', FeedOrder.oldestFirst);
    await store.set('new', FeedOrder.oldestFirst);
    expect(store.orderOf('f0'), FeedOrder.oldestFirst);
    expect(store.orderOf('f1'), FeedOrder.newestFirst);
  });

  test('over 2000 from disk is trimmed on restore', () async {
    final big = {for (var i = 0; i < 2100; i++) 'f$i': 'oldest'};
    final box = MemoryBox(jsonEncode({'feeds': big}));
    final store = FeedOrderStore(box);
    await store.restore();
    expect(store.orderOf('f0'), FeedOrder.newestFirst);
    expect(store.orderOf('f99'), FeedOrder.newestFirst);
    expect(store.orderOf('f100'), FeedOrder.oldestFirst);
    expect(store.orderOf('f2099'), FeedOrder.oldestFirst);
    await store.set('x', FeedOrder.oldestFirst);
    expect(box.feeds.length, 2000);
    expect(store.orderOf('x'), FeedOrder.oldestFirst);
  });

  test('user logout wipes everything on disk and in memory', () async {
    final box = MemoryBox();
    final store = FeedOrderStore(box);
    await store.restore();
    await store.set(a, FeedOrder.oldestFirst);
    var calls = 0;
    store.addListener(() => calls++);
    await store.clear();
    expect(calls, greaterThanOrEqualTo(1));
    expect(store.orderOf(a), FeedOrder.newestFirst);
    expect(box.feeds, isEmpty);
    final again = FeedOrderStore(box);
    await again.restore();
    expect(again.orderOf(a), FeedOrder.newestFirst);
  });

  test(
    'after clear, delayed set does not restore previous user choice',
    () async {
      final box = MemoryBox();
      final store = FeedOrderStore(box);
      await store.restore();
      await store.clear();
      await store.set(a, FeedOrder.oldestFirst);
      expect(store.orderOf(a), FeedOrder.newestFirst);
      expect(box.feeds, isEmpty);
    },
  );

  test('after clear and new restore selection works again', () async {
    final box = MemoryBox();
    final store = FeedOrderStore(box);
    await store.restore();
    await store.clear();
    await store.restore();
    await store.set(b, FeedOrder.oldestFirst);
    expect(store.orderOf(b), FeedOrder.oldestFirst);
    expect(box.feeds, {b: 'oldest'});
  });

  test('long feed address and unicode preserved as is', () async {
    final url = 'https://подкаст.example/${'x' * 3000}?a=1&b=2';
    final box = MemoryBox();
    final store = FeedOrderStore(box);
    await store.restore();
    await store.set(url, FeedOrder.oldestFirst);
    final again = FeedOrderStore(box);
    await again.restore();
    expect(again.orderOf(url), FeedOrder.oldestFirst);
  });
}
