import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/book_position.dart';
import 'package:music_stream/continue_shelf.dart';
import 'package:music_stream/podcast_progress.dart';

// Lead check FT-709 (Pd-1). Executor does not modify this file.
//
// Disk format contract: JSON {"items": [ContinueMeta.toJson(), ...]} — oldest to newest.

class MemoryBox implements ContinueBox {
  MemoryBox([this.data]);
  String? data;
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
    data = value;
  }

  List<dynamic> get items => (jsonDecode(data!) as Map)['items'] as List;
}

final t0 = DateTime.utc(2026, 10, 9, 12);
DateTime at(int minutes) => t0.add(Duration(minutes: minutes));

ContinueMeta ep(
  String key, {
  int? durationMs = 3600000,
  String title = 'Выпуск',
}) => ContinueMeta(
  kind: ContinueKind.podcast,
  key: key,
  title: title,
  subtitle: 'Подкаст',
  imageUrl: 'https://img.example/$key.jpg',
  durationMs: durationMs,
);

ContinueMeta book(String key, {int parts = 24}) => ContinueMeta(
  kind: ContinueKind.book,
  key: key,
  title: 'Книга',
  subtitle: 'Автор',
  partCount: parts,
);

class World {
  final Map<String, EpisodeProgress> eps = {};
  final Map<String, BookPosition> books = {};
  final Set<String> gone = {};
  late final MemoryBox box = MemoryBox();

  ContinueShelf shelf([ContinueBox? b]) => ContinueShelf(
    b ?? box,
    podcast: (k) => eps[k],
    book: (k) => books[k],
    available: (m) => !gone.contains(m.key),
  );

  void listen(String key, int positionMs, int minute, {bool done = false}) =>
      eps[key] = EpisodeProgress(
        positionMs: positionMs,
        done: done,
        updatedAt: at(minute),
      );

  void read(
    String key,
    int part,
    int positionMs,
    int minute, {
    bool finished = false,
  }) => books[key] = BookPosition(
    part: part,
    positionMs: positionMs,
    finished: finished,
    updatedAt: at(minute),
  );
}

List<String> keys(ContinueShelf s, {int limit = 10}) =>
    s.items(limit: limit).map((i) => i.meta.key).toList();

class GatedBox implements ContinueBox {
  GatedBox(this.data);
  String? data;
  final gate = Completer<void>();
  final List<int> writeDelaysMs = [];
  int writes = 0;

  @override
  Future<String?> read() async {
    await gate.future;
    return data;
  }

  @override
  Future<void> write(String value) async {
    writes++;
    final d = writeDelaysMs.isEmpty ? 0 : writeDelaysMs.removeAt(0);
    await Future<void>.delayed(Duration(milliseconds: d));
    data = value;
  }

  List<dynamic> get items => (jsonDecode(data!) as Map)['items'] as List;
}

void main() {
  test('empty: returns empty list', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    expect(s.items(), isEmpty);
  });

  test('started episode: title, position, remaining duration', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1'));
    w.listen('e1', 600000, 1);
    final item = s.items().single;
    expect(item.meta.title, 'Выпуск');
    expect(item.meta.imageUrl, 'https://img.example/e1.jpg');
    expect(item.positionMs, 600000);
    expect(item.remainingMs, 3000000);
    expect(item.part, isNull);
    expect(item.updatedAt, at(1));
  });

  test('unknown duration: remaining time is also unknown', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1', durationMs: null));
    w.listen('e1', 600000, 1);
    expect(s.items().single.remainingMs, isNull);
    await s.remember(ep('e1', durationMs: 0));
    expect(s.items().single.remainingMs, isNull);
  });

  test(
    'started but no position or under 10 seconds: not shown on shelf',
    () async {
      final w = World();
      final s = w.shelf();
      await s.restore();
      await s.remember(ep('none'));
      await s.remember(ep('short'));
      await s.remember(ep('edge'));
      w.listen('short', 9999, 1);
      w.listen('edge', 10000, 2);
      expect(keys(s), ['edge']);
    },
  );

  test('completed episode disappears', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1'));
    w.listen('e1', 600000, 1);
    expect(keys(s), ['e1']);
    w.listen('e1', 600000, 2, done: true);
    expect(keys(s), isEmpty);
  });

  test('position at very end of episode: completed, not shown', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1', durationMs: 3600000));
    w.listen('e1', 3600000, 1);
    expect(keys(s), isEmpty);
  });

  test('book: part and position; remaining is not computed', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(book('b1'));
    w.read('b1', 3, 120000, 1);
    final item = s.items().single;
    expect(item.part, 3);
    expect(item.meta.partCount, 24);
    expect(item.positionMs, 120000);
    expect(item.remainingMs, isNull);
  });

  test(
    'book at start of part 1 not shown; shown starting from part 2',
    () async {
      final w = World();
      final s = w.shelf();
      await s.restore();
      await s.remember(book('b1'));
      await s.remember(book('b2'));
      w.read('b1', 1, 5000, 1);
      w.read('b2', 2, 0, 2);
      expect(keys(s), ['b2']);
    },
  );

  test('completed book disappears', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(book('b1'));
    w.read('b1', 24, 0, 1, finished: true);
    expect(keys(s), isEmpty);
  });

  test('removed book is not shown, but entry remains remembered', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(book('b1'));
    w.read('b1', 3, 0, 1);
    w.gone.add('b1');
    expect(keys(s), isEmpty);
    w.gone.clear();
    expect(keys(s), ['b1']);
  });

  test('newest entries first by position time, not remember call', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1'));
    await s.remember(book('b1'));
    await s.remember(ep('e2'));
    w.listen('e1', 60000, 30);
    w.read('b1', 2, 0, 10);
    w.listen('e2', 60000, 20);
    expect(keys(s), ['e1', 'e2', 'b1']);
  });

  test('position without remember is not shown on shelf', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    w.listen('e1', 600000, 1);
    expect(keys(s), isEmpty);
  });

  test('limit cuts list; default is 10', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    for (var i = 0; i < 15; i++) {
      await s.remember(ep('e$i'));
      w.listen('e$i', 60000, i);
    }
    expect(s.items().length, 10);
    expect(s.items().first.meta.key, 'e14');
    expect(keys(s, limit: 3), ['e14', 'e13', 'e12']);
    expect(s.items(limit: 0), isEmpty);
  });

  test('subsequent remember updates title', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1', title: 'Старое'));
    await s.remember(ep('e1', title: 'Новое'));
    w.listen('e1', 60000, 1);
    expect(s.items().single.meta.title, 'Новое');
  });

  test('forget removes entry', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1'));
    w.listen('e1', 60000, 1);
    await s.forget('e1');
    expect(keys(s), isEmpty);
    expect(w.box.items, isEmpty);
  });

  test('at most 50 entries: oldest remembered entries evicted', () async {
    expect(ContinueShelf.maxEntries, 50);
    final w = World();
    final s = w.shelf();
    await s.restore();
    for (var i = 0; i < 60; i++) {
      await s.remember(ep('e$i'));
      w.listen('e$i', 60000, 1000 - i);
    }
    expect(w.box.items.length, 50);
    expect(s.items(limit: 100).length, 50);
    expect(keys(s, limit: 100), isNot(contains('e9')));
    expect(keys(s, limit: 100), contains('e10'));
  });

  test('repeat remember refreshes entry: not evicted first', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    for (var i = 0; i < 50; i++) {
      await s.remember(ep('e$i'));
      w.listen('e$i', 60000, i);
    }
    await s.remember(ep('e0'));
    await s.remember(ep('new'));
    w.listen('new', 60000, 99);
    expect(keys(s, limit: 100), contains('e0'));
    expect(keys(s, limit: 100), isNot(contains('e1')));
  });

  test('survives app restart, on-disk format', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    await s.remember(ep('e1'));
    await s.remember(book('b1'));
    expect(w.box.items.map((e) => e['key']), ['e1', 'b1']);
    expect(w.box.items.first['kind'], 'podcast');
    expect(w.box.items.last['kind'], 'book');
    w.listen('e1', 60000, 1);
    w.read('b1', 2, 0, 2);
    final again = w.shelf();
    await again.restore();
    expect(keys(again), ['b1', 'e1']);
    expect(again.items().last.meta.durationMs, 3600000);
    expect(again.items().first.meta.partCount, 24);
  });

  for (final broken in [
    '',
    'not json',
    '[1]',
    '{"items": 5}',
    'null',
    '{"items": [1, {"kind": "x"}]}',
  ]) {
    test('corrupt data $broken does not crash launch', () async {
      final w = World();
      final s = w.shelf(MemoryBox(broken));
      await s.restore();
      expect(s.items(), isEmpty);
      await s.remember(ep('e1'));
      w.listen('e1', 60000, 1);
      expect(keys(s), ['e1']);
    });
  }

  test('corrupt entry discarded, adjacent entries survive', () async {
    final w = World();
    final good = ep('e1').toJson();
    final box = MemoryBox(
      jsonEncode({
        'items': [
          {...good, 'key': 'e2', 'duration_ms': 'long'},
          {...good, 'key': 'e3', 'image': 5},
          {...good, 'key': 'e4', 'parts': '24'},
          {'kind': 'podcast', 'key': 'bad'},
          good,
        ],
      }),
    );
    final s = w.shelf(box);
    await s.restore();
    for (final k in ['e1', 'e2', 'e3', 'e4', 'bad']) {
      w.listen(k, 60000, 1);
    }
    expect(keys(s), ['e1']);
  });

  test(
    'entry remembered prior to restore is fresh and not evicted first',
    () async {
      final w = World();
      final box = MemoryBox(
        jsonEncode({
          'items': [for (var i = 0; i < 50; i++) ep('e$i').toJson()],
        }),
      );
      final s = w.shelf(box);
      await s.remember(ep('e0'));
      await s.restore();
      await s.remember(ep('new'));
      for (final k in ['e0', 'e1', 'new']) {
        w.listen(k, 60000, 1);
      }
      expect(keys(s, limit: 100), contains('e0'));
      expect(keys(s, limit: 100), isNot(contains('e1')));
    },
  );

  test('disk errors do not crash calls', () async {
    final w = World();
    final box = MemoryBox()
      ..failRead = true
      ..failWrite = true;
    final s = w.shelf(box);
    await s.restore();
    await s.remember(ep('e1'));
    w.listen('e1', 60000, 1);
    expect(keys(s), ['e1']);
    await s.forget('e1');
    await s.clear();
  });

  test('remember before restore does not clear disk and wins', () async {
    final w = World();
    final box = MemoryBox(
      jsonEncode({
        'items': [ep('e1', title: 'С диска').toJson(), ep('e2').toJson()],
      }),
    );
    final s = w.shelf(box);
    await s.remember(ep('e1', title: 'Свежее'));
    expect(box.items.length, 2);
    await s.restore();
    w.listen('e1', 60000, 1);
    w.listen('e2', 60000, 2);
    expect(keys(s), ['e2', 'e1']);
    expect(s.items().last.meta.title, 'Свежее');
    expect(box.items.map((e) => e['title']), contains('Свежее'));
  });

  test(
    'remember during disk read: disk is untouched, entry is not lost',
    () async {
      final w = World();
      final box = GatedBox(
        jsonEncode({
          'items': [ep('e1').toJson(), ep('e2').toJson()],
        }),
      );
      final s = w.shelf(box);
      final restoring = s.restore();
      await s.remember(ep('e3'));
      expect(box.writes, 0);
      box.gate.complete();
      await restoring;
      for (final k in ['e1', 'e2', 'e3']) {
        w.listen(k, 60000, 1);
      }
      expect(keys(s)..sort(), ['e1', 'e2', 'e3']);
      expect(box.items.map((e) => e['key']), ['e1', 'e2', 'e3']);
    },
  );

  test(
    'disk read failed: subsequent remember does not wipe saved data',
    () async {
      final w = World();
      final saved = jsonEncode({
        'items': [ep('e1').toJson()],
      });
      final box = MemoryBox(saved)..failRead = true;
      final s = w.shelf(box);
      await s.restore();
      await s.remember(ep('e2'));
      await s.forget('e2');
      expect(box.data, saved);
    },
  );

  test('disk writes are serialized: newest write lands last', () async {
    final w = World();
    final box = GatedBox(null)..gate.complete();
    final s = w.shelf(box);
    await s.restore();
    box.writeDelaysMs.addAll([50, 0]);
    final first = s.remember(ep('e1'));
    final second = s.remember(ep('e2'));
    await Future.wait([first, second]);
    expect(box.items.map((e) => e['key']), ['e1', 'e2']);
  });

  test('toString omits titles (log without titles)', () {
    final m = ep('e1', title: 'Секретное название');
    expect(m.toString(), isNot(contains('Секретное')));
  });

  test('listeners notified of remember and forget', () async {
    final w = World();
    final s = w.shelf();
    await s.restore();
    var calls = 0;
    s.addListener(() => calls++);
    await s.remember(ep('e1'));
    expect(calls, 1);
    await s.forget('e1');
    expect(calls, 2);
    await s.forget('e1');
    expect(calls, 2);
  });

  test(
    'user logout wipes all; late remember does not restore old data',
    () async {
      final w = World();
      final s = w.shelf();
      await s.restore();
      await s.remember(ep('e1'));
      w.listen('e1', 60000, 1);
      await s.clear();
      expect(keys(s), isEmpty);
      expect(w.box.items, isEmpty);
      await s.remember(ep('e2'));
      w.listen('e2', 60000, 2);
      expect(keys(s), isEmpty);
      expect(w.box.items, isEmpty);
      await s.restore();
      await s.remember(ep('e3'));
      w.listen('e3', 60000, 3);
      expect(keys(s), ['e3']);
    },
  );
}
