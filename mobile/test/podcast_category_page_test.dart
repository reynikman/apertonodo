import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_stream/podcast_client.dart';
import 'package:music_stream/screens/podcast_category_page.dart';

// Lead check FT-704 (Pk-3). Executor does not modify this file.

const texts = PodcastCategoryTexts(
  loadFailed: 'Не удалось загрузить',
  retry: 'Повторить',
  empty: 'В этом разделе пока пусто',
  subscribe: 'Подписаться',
  subscribed: 'Вы подписаны',
  subscribeFailed: 'Не удалось подписаться',
);

const a = FoundPodcast(
  feedUrl: 'https://a.example/feed',
  title: 'Арзамас',
  author: 'Арзамас',
);
const b = FoundPodcast(
  feedUrl: 'https://b.example/feed',
  title: 'Радио Т',
  author: '',
);
const c = FoundPodcast(
  feedUrl: 'https://c.example/feed',
  title: 'Подлодка',
  author: 'Команда',
);

class Harness {
  int loads = 0;
  final opened = <String>[];
  final subscribeCalls = <String>[];
  Future<List<FoundPodcast>> Function() loader = () async => [a, b, c];
  Future<bool> Function(FoundPodcast) subscriber = (_) async => true;
  Set<String> subscribed = {};

  Widget build({String title = 'Наука'}) => MaterialApp(
    home: PodcastCategoryPage(
      title: title,
      load: () {
        loads++;
        return loader();
      },
      subscribed: subscribed,
      onSubscribe: (p) {
        subscribeCalls.add(p.feedUrl);
        return subscriber(p);
      },
      onOpen: (p) => opened.add(p.feedUrl),
      texts: texts,
    ),
  );
}

Finder subscribeOf(FoundPodcast p) =>
    find.byKey(ValueKey('subscribe-${p.feedUrl}'));
Finder subscribedOf(FoundPodcast p) =>
    find.byKey(ValueKey('subscribed-${p.feedUrl}'));

void main() {
  testWidgets('section title in header', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.build(title: 'История'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('История')),
      findsOneWidget,
    );
  });

  testWidgets('while loading — spinner, no list', (tester) async {
    final h = Harness();
    final gate = Completer<List<FoundPodcast>>();
    h.loader = () => gate.future;
    await tester.pumpWidget(h.build());
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Арзамас'), findsNothing);
    gate.complete([a]);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('list: titles of all podcasts in server response order', (
    tester,
  ) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    final ya = tester.getTopLeft(find.text('Арзамас').first).dy;
    final yb = tester.getTopLeft(find.text('Радио Т')).dy;
    final yc = tester.getTopLeft(find.text('Подлодка')).dy;
    expect(ya < yb && yb < yc, isTrue);
    expect(h.loads, 1);
  });

  testWidgets('author shown, empty author adds no line', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(find.text('Команда'), findsOneWidget);
    expect(find.text('Арзамас'), findsNWidgets(2)); // title and author
    final tileB = find.byKey(ValueKey('podcast-${b.feedUrl}'));
    expect(
      find.descendant(of: tileB, matching: find.byType(Text)).evaluate().length,
      2,
    ); // title + button
  });

  testWidgets('each unsubscribed has «Subscribe»', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    for (final p in [a, b, c]) {
      expect(subscribeOf(p), findsOneWidget);
      expect(subscribedOf(p), findsNothing);
    }
    expect(find.text('Подписаться'), findsNWidgets(3));
  });

  testWidgets('already subscribed shows «Subscribed», no button', (
    tester,
  ) async {
    final h = Harness()..subscribed = {b.feedUrl};
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(subscribedOf(b), findsOneWidget);
    expect(subscribeOf(b), findsNothing);
    expect(find.text('Вы подписаны'), findsOneWidget);
    expect(subscribeOf(a), findsOneWidget);
  });

  testWidgets('subscription: calls onSubscribe once and updates button', (
    tester,
  ) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.tap(subscribeOf(c));
    await tester.pumpAndSettle();
    expect(h.subscribeCalls, [c.feedUrl]);
    expect(subscribedOf(c), findsOneWidget);
    expect(subscribeOf(c), findsNothing);
    expect(subscribeOf(a), findsOneWidget);
    expect(h.opened, isEmpty); // tapping the button does not open the podcast
  });

  testWidgets('while subscribing — button disabled, no second call', (
    tester,
  ) async {
    final h = Harness();
    final gate = Completer<bool>();
    h.subscriber = (_) => gate.future;
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.tap(subscribeOf(a));
    await tester.pump();
    final btn = tester.widget<TextButton>(subscribeOf(a));
    expect(btn.onPressed, isNull);
    await tester.tap(subscribeOf(a), warnIfMissed: false);
    await tester.pump();
    expect(h.subscribeCalls, [a.feedUrl]);
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(subscribedOf(a), findsOneWidget);
  });

  testWidgets('subscription failure: button stays, message shown', (
    tester,
  ) async {
    final h = Harness()..subscriber = (_) async => false;
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.tap(subscribeOf(a));
    await tester.pumpAndSettle();
    expect(subscribedOf(a), findsNothing);
    expect(subscribeOf(a), findsOneWidget);
    expect(tester.widget<TextButton>(subscribeOf(a)).onPressed, isNotNull);
    expect(find.text('Не удалось подписаться'), findsOneWidget);
  });

  testWidgets('subscription exception — failure, no crash', (tester) async {
    final h = Harness()..subscriber = (_) async => throw Exception('сеть');
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.tap(subscribeOf(b));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(subscribeOf(b), findsOneWidget);
    expect(find.text('Не удалось подписаться'), findsOneWidget);
  });

  testWidgets('successful subscribe produces no error', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.tap(subscribeOf(a));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось подписаться'), findsNothing);
  });

  testWidgets('tapping row opens podcast', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подлодка'));
    await tester.pumpAndSettle();
    expect(h.opened, [c.feedUrl]);
    expect(h.subscribeCalls, isEmpty);
  });

  testWidgets('empty category — text, no list', (tester) async {
    final h = Harness()..loader = () async => [];
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(find.text('В этом разделе пока пусто'), findsOneWidget);
    expect(find.text('Подписаться'), findsNothing);
  });

  testWidgets('load error — text and «Retry»', (tester) async {
    final h = Harness()
      ..loader = () async =>
          throw const PodcastException(PodcastFailure.unavailable);
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    expect(find.text('В этом разделе пока пусто'), findsNothing);
  });

  testWidgets('«Retry» reloads and shows list', (tester) async {
    final h = Harness();
    var fail = true;
    h.loader = () async {
      if (fail) throw const PodcastException(PodcastFailure.unavailable);
      return [a];
    };
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    fail = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(h.loads, 2);
    expect(find.text('Арзамас'), findsWidgets);
    expect(find.text('Не удалось загрузить'), findsNothing);
  });

  testWidgets('page rebuild does not reload category', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(h.loads, 1);
  });

  testWidgets('row height at least 48 dp (touch target)', (tester) async {
    final h = Harness();
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byKey(ValueKey('podcast-${a.feedUrl}')));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(tester.getSize(subscribeOf(a)).height, greaterThanOrEqualTo(48));
  });

  testWidgets('long title does not break layout on 360', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final long = FoundPodcast(
      feedUrl: 'https://l.example/feed',
      title: 'Очень ' * 40,
      author: 'Автор ' * 30,
    );
    final h = Harness()..loader = () async => [long];
    await tester.pumpWidget(h.build());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(subscribeOf(long), findsOneWidget);
    final row = find.byKey(const ValueKey('podcast-https://l.example/feed'));
    expect(
      tester.getSize(row).height,
      lessThan(100),
    ); // title and author — one line each
  });

  testWidgets(
    'subscribing to slow podcast after leaving page does not crash at all',
    (tester) async {
      final h = Harness();
      final gate = Completer<bool>();
      h.subscriber = (_) => gate.future;
      await tester.pumpWidget(h.build());
      await tester.pumpAndSettle();
      await tester.tap(subscribeOf(a));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      gate.complete(false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
