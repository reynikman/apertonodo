// FT-691: "network returned" signal (P-A85, draft Bt-1a). Lead check written before work.
//
// Contract:
// - event `returned` is "offline -> online" transition where "online" holds for `settle` (default 2 s);
// - network lost before `settle` — no event; repeated consecutive "online" — single event;
// - start: port's `isOnline`; port failure — treated as "online" (no false "returned");
// - before `start` and when `isOnline` is unknown — `true`;
// - port stream errors swallowed, stream closing — no more events and pending canceled;
// - `dispose` unsubscribes from port and closes `returned`; repeated `start`/`dispose` — no-op.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/network_watch.dart';

class FakePort implements NetworkPort {
  FakePort({this.now = true, this.throwOnAsk = false});

  bool now;
  bool throwOnAsk;
  int asks = 0;
  Completer<bool>? answer;
  final controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get online => controller.stream;

  @override
  Future<bool> get isOnline async {
    asks++;
    if (throwOnAsk) throw StateError('нет сервиса');
    final a = answer;
    if (a != null) return a.future;
    return now;
  }

  void send(bool value) => controller.add(value);
}

/// Event subscription and counter.
class Counter {
  Counter(NetworkWatch w) {
    sub = w.returned.listen((_) => count++);
  }
  int count = 0;
  late final StreamSubscription<void> sub;
}

Future<void> step(WidgetTester t, [int ms = 0]) =>
    t.pump(Duration(milliseconds: ms));

void main() {
  testWidgets('no → yes holding for 2s — single event', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    expect(w.isOnline, isFalse);
    port.send(true);
    await step(t, 1999);
    expect(c.count, 0);
    await step(t, 1);
    expect(c.count, 1);
    expect(w.isOnline, isTrue);
    await w.dispose();
  });

  testWidgets('no → yes → no before 2s — no event', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.send(true);
    await step(t, 1500);
    port.send(false);
    await step(t, 5000);
    expect(c.count, 0);
    expect(w.isOnline, isFalse);
    await w.dispose();
  });

  testWidgets(
    'flapping, then real return — single event emitted, timer resets now',
    (t) async {
      final port = FakePort(now: false);
      final w = NetworkWatch(port);
      final c = Counter(w);
      await w.start();
      port.send(true);
      await step(t, 1000);
      port.send(false);
      await step(t, 100);
      port.send(true);
      await step(t, 1900);
      expect(c.count, 0, reason: '2s timer counts from last «yes»');
      await step(t, 100);
      expect(c.count, 1);
      await w.dispose();
    },
  );

  testWidgets('no → yes → no → yes — two events', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.send(true);
    await step(t, 2000);
    port.send(false);
    await step(t, 500);
    port.send(true);
    await step(t, 2000);
    expect(c.count, 2);
    await w.dispose();
  });

  testWidgets('yes → yes — zero events', (t) async {
    final port = FakePort(now: true);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.send(true);
    port.send(true);
    await step(t, 10000);
    expect(c.count, 0);
    expect(w.isOnline, isTrue);
    await w.dispose();
  });

  testWidgets('repeated «yes» after return — single event', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.send(true);
    await step(t, 500);
    port.send(true);
    await step(t, 500);
    port.send(true);
    await step(t, 5000);
    expect(c.count, 1);
    await w.dispose();
  });

  testWidgets('repeated consecutive «no» do not interfere', (t) async {
    final port = FakePort(now: true);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.send(false);
    port.send(false);
    await step(t, 100);
    expect(w.isOnline, isFalse);
    port.send(true);
    await step(t, 2000);
    expect(c.count, 1);
    await w.dispose();
  });

  testWidgets('start online: dropped and returned — event', (t) async {
    final port = FakePort(now: true);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.send(false);
    await step(t, 100);
    port.send(true);
    await step(t, 2000);
    expect(c.count, 1);
    await w.dispose();
  });

  testWidgets('custom settle delay', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port, settle: const Duration(milliseconds: 300));
    expect(w.settle, const Duration(milliseconds: 300));
    final c = Counter(w);
    await w.start();
    port.send(true);
    await step(t, 299);
    expect(c.count, 0);
    await step(t, 1);
    expect(c.count, 1);
    await w.dispose();
  });

  testWidgets('default settle delay — 2s', (t) async {
    expect(NetworkWatch(FakePort()).settle, const Duration(seconds: 2));
  });

  testWidgets('before start — isOnline true, port unpolled', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    expect(w.isOnline, isTrue);
    expect(port.asks, 0);
    await w.dispose();
  });

  testWidgets('port error on start treated as «yes», no false event', (
    t,
  ) async {
    final port = FakePort(now: false, throwOnAsk: true);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    expect(w.isOnline, isTrue);
    port.send(true);
    await step(t, 5000);
    expect(c.count, 0);
    port.send(false);
    await step(t, 10);
    port.send(true);
    await step(t, 2000);
    expect(c.count, 1);
    await w.dispose();
  });

  testWidgets('repeated start does not query port or double-subscribe', (
    t,
  ) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    await w.start();
    expect(port.asks, 1);
    port.send(true);
    await step(t, 2000);
    expect(c.count, 1, reason: 'two subscriptions would emit twice');
    await w.dispose();
  });

  testWidgets('port stream error does not block next events', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.controller.addError(StateError('сбой'));
    await step(t, 10);
    port.send(true);
    await step(t, 2000);
    expect(c.count, 1);
    await w.dispose();
  });

  testWidgets('port stream closed during countdown — no event', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    await w.start();
    port.send(true);
    await step(t, 1000);
    await port.controller.close();
    await step(t, 5000);
    expect(c.count, 0);
    await w.dispose();
  });

  testWidgets('dispose during countdown — no event, stream is closed', (
    t,
  ) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final c = Counter(w);
    var done = false;
    w.returned.listen((_) {}, onDone: () => done = true);
    await w.start();
    port.send(true);
    await step(t, 1000);
    await w.dispose();
    await step(t, 5000);
    expect(c.count, 0);
    expect(done, isTrue);
    expect(port.controller.hasListener, isFalse);
    await w.dispose();
  });

  testWidgets('after dispose, start is a no-op', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    await w.dispose();
    await w.start();
    expect(port.asks, 0);
    expect(port.controller.hasListener, isFalse);
  });

  testWidgets('dispose unsubscribes from port', (t) async {
    final port = FakePort(now: true);
    final w = NetworkWatch(port);
    await w.start();
    expect(port.controller.hasListener, isTrue);
    await w.dispose();
    expect(port.controller.hasListener, isFalse);
  });

  testWidgets('events observed by multiple listeners', (t) async {
    final port = FakePort(now: false);
    final w = NetworkWatch(port);
    final a = Counter(w);
    final b = Counter(w);
    await w.start();
    port.send(true);
    await step(t, 2000);
    expect(a.count, 1);
    expect(b.count, 1);
    await w.dispose();
  });

  testWidgets('dispose while port answers start — no subscription made', (
    t,
  ) async {
    final port = FakePort(now: false)..answer = Completer<bool>();
    final w = NetworkWatch(port);
    final c = Counter(w);
    final started = w.start();
    await w.dispose();
    port.answer!.complete(false);
    await started;
    expect(port.controller.hasListener, isFalse);
    port.send(true);
    await step(t, 5000);
    expect(c.count, 0);
  });
}
