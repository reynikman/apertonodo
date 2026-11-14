import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:music_stream/auth/login.dart';
import 'package:music_stream/env.dart';
import 'package:music_stream/auth/session_store.dart';
import 'package:music_stream/main.dart';
import 'package:music_stream/offline/track_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// FT-899. After the server moved, phones keep `server-moved-from` (the old
// address) next to `active-server` (the new one). Downloaded songs, podcast
// episodes and "allow mobile network" still live under the namespace of the
// OLD address. The app has no table of old addresses: it reads the pref, and
// only a person on the build's default address gets the old space back.
const _old = 'https://old.example.org';
final _default = AppEnv.apiBaseUrl;
const _other = 'https://other.example.org';

Uri _uri(String origin) => Uri.parse(origin);

class _Run {
  final opened = <String>[];
  final stores = <TrackStore>[];

  /// Requests made after the account (user-1) was read: by then the app
  /// has made up its mind which address it talks to.
  final afterAccount = <Uri>[];
  final all = <Uri>[];

  /// Requests after the account was read that carried the token.
  final withToken = <Uri>[];

  /// Address shown on the login screen (null: the address step, nothing offered).
  String? offered;
}

void main() {
  sqfliteFfiInit();

  late Directory root;
  String? token;

  setUp(() {
    token = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'write') {
          token = (call.arguments as Map)['value'] as String;
        }
        if (call.method == 'delete') token = null;
        if (call.method == 'read') return token;
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.bbflight.background_downloader'),
      (call) async => null,
    );
    for (final name in const [
      'dev.fluttercommunity.plus/connectivity',
      'dev.fluttercommunity.plus/connectivity_status',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => call.method == 'check' ? ['wifi'] : null,
      );
    }
  });

  Future<void> prepare(
    WidgetTester tester,
    Map<String, Object> prefs, {
    bool signedIn = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'music-space-chosen': true,
      ...prefs,
    });
    token = signedIn ? List.filled(32, '7').join() : null;
    root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('server_rename_test'),
    ))!;
    addTearDown(() => root.delete(recursive: true));
  }

  Future<TrackStore> openIn(String namespace) => TrackStore.open(
    root: root,
    namespace: namespace,
    databaseFactory: databaseFactoryFfi,
    now: DateTime.now,
    freeBytes: () async => null,
  );

  /// A downloaded file under [namespace]; returns the store's own key
  /// (the hash that all `podcast_downloads_<ns>_…` keys use).
  Future<String> download(String namespace, List<String> ids) async {
    final store = await openIn(namespace);
    for (final id in ids) {
      await store.partFile(id, format: 'mp3').writeAsBytes([1, 2, 3]);
      await store.commit(id, format: 'mp3', hold: Hold.download);
    }
    final key = store.namespace;
    await store.close();
    return key;
  }

  /// Nothing was copied: no directory under the namespace of the new origin.
  void noCopy() {
    final hash = sha256
        .convert(utf8.encode(accountNamespace(_uri(_default), 'user-1')))
        .toString();
    expect(
      Directory('${root.path}/$hash').existsSync(),
      isFalse,
      reason: 'data was copied under the namespace of the new address',
    );
  }

  /// What the app does at start: `main()` reads `active-server` and hands it
  /// over as `initialServer`; then `_loadAccount` reads the account.
  Future<_Run> launch(
    WidgetTester tester, {
    int unauthorized = 0,
    bool signIn = false,
    Future<void> Function(_Run run)? whenSettled,
  }) async {
    final run = _Run();
    final prefs = await SharedPreferences.getInstance();
    final client = MockClient((request) async {
      run.all.add(request.url);
      if (run.opened.any((n) => n.endsWith('/user-1'))) {
        run.afterAccount.add(request.url);
        if ((request.headers['authorization'] ?? '').startsWith('Bearer ')) {
          run.withToken.add(request.url);
        }
      }
      if (request.url.path == '/v1/health') {
        return http.Response(
          jsonEncode({'status': 'ok'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/v1/auth/login') {
        return http.Response(
          jsonEncode({'token': 'a' * 32, 'user_id': 'user-1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', unauthorized > 0 ? 401 : 404);
    });
    Future<TrackStore> open(String namespace) async {
      run.opened.add(namespace);
      final store = await openIn(namespace);
      run.stores.add(store);
      return store;
    }

    await tester.runAsync(() async {
      final sessions = SessionStore();
      await sessions.readToken();
      await tester.pumpWidget(
        buildProductionApp(
          sessions: sessions,
          client: client,
          initialServer: _initialServer(prefs.getString('active-server')),
          openStore: open,
        ),
      );
      if (signIn) {
        // Cold start without a token: the login screen, then a real sign-in.
        bool has(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;
        await _wait(
          tester,
          () => has('login-username') || has('server-address-field'),
        );
        if (has('server-address-field')) {
          // The wizard did not offer an address: type the default address by hand,
          // so the rest of the scenario still runs and fails on its own line.
          run.offered = null;
          await tester.enterText(
            find.byKey(const Key('server-address-field')),
            _default,
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('server-address-next')));
          await _wait(tester, () => has('login-username'));
        } else {
          run.offered = tester
              .widget<Text>(find.byKey(const Key('wizard-server')))
              .data;
        }
        await tester.enterText(find.byKey(const Key('login-username')), 'u');
        await tester.enterText(find.byKey(const Key('login-password')), 'p');
        await tester.pump();
        await tester.tap(find.byKey(const Key('login-submit')));
      }
      await _wait(
        tester,
        () =>
            run.opened.any((n) => n.endsWith('/user-1')) &&
            // opened is noted before openIn finishes; stores only after it.
            run.stores.length == run.opened.length &&
            run.afterAccount.isNotEmpty,
        steps: 500,
      );
      await whenSettled?.call(run);
    });
    return run;
  }

  Future<void> stop(WidgetTester tester, _Run run) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final store in run.stores) {
        try {
          await store.close();
        } catch (_) {}
      }
    });
  }

  Future<String?> saved(WidgetTester tester) async {
    final value = await tester.runAsync<String?>(() async {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('active-server');
    });
    return value;
  }

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(
      () => download(accountNamespace(_uri(_old), 'user-1'), ['song-1']),
    );
  }

  testWidgets('moved phone on the default address sees the old space', (
    tester,
  ) async {
    await prepare(tester, {
      'active-server': _default,
      'server-moved-from': _old,
      'active-user': 'user-1',
    });
    await seed(tester);
    final run = await launch(tester);

    expect(run.opened.last, accountNamespace(_uri(_old), 'user-1'));
    expect(await saved(tester), _default);
    noCopy();
    final file = await tester.runAsync(() => run.stores.last.fileFor('song-1'));
    expect(file, isNotNull, reason: 'the downloaded song is not visible');
    await stop(tester, run);
  });

  testWidgets('moved phone signed in on another server does not see it', (
    tester,
  ) async {
    await prepare(tester, {
      'active-server': _other,
      'server-moved-from': _old,
      'active-user': 'user-1',
    });
    await seed(tester);
    final run = await launch(tester);

    expect(run.opened.last, accountNamespace(_uri(_other), 'user-1'));
    final file = await tester.runAsync(() => run.stores.last.fileFor('song-1'));
    expect(file, isNull, reason: 'the old space belongs to the default server');
    await stop(tester, run);
  });

  testWidgets('phone without server-moved-from uses the current address', (
    tester,
  ) async {
    await prepare(tester, {'active-server': _default, 'active-user': 'user-1'});
    await seed(tester);
    final run = await launch(tester);

    expect(run.opened.last, accountNamespace(_uri(_default), 'user-1'));
    final file = await tester.runAsync(() => run.stores.last.fileFor('song-1'));
    expect(file, isNull);
    await stop(tester, run);
  });

  for (final address in const [
    'https://home.example.org:4533',
    'https://music.example',
    _other,
  ]) {
    testWidgets('saved address $address is never replaced', (tester) async {
      await prepare(tester, {
        'active-server': address,
        'active-user': 'user-1',
      });
      final run = await launch(tester);

      expect(await saved(tester), address);
      expect(run.opened.last, accountNamespace(_uri(address), 'user-1'));
      expect(run.afterAccount.map((u) => u.origin).toSet(), {address});
      await stop(tester, run);
    });
  }

  testWidgets('cold start without token, moved pref set: sign-in keeps old '
      'namespace', (tester) async {
    await prepare(tester, {
      'active-server': _default,
      'server-moved-from': _old,
      'active-user': 'user-1',
    }, signedIn: false);
    await seed(tester);
    final run = await launch(tester, signIn: true);

    expect(run.opened.last, accountNamespace(_uri(_old), 'user-1'));
    expect(
      run.opened.contains(accountNamespace(_uri(_default), 'user-1')),
      isFalse,
    );
    final file = await tester.runAsync(() => run.stores.last.fileFor('song-1'));
    expect(file, isNotNull);
    expect(await saved(tester), _default);
    await stop(tester, run);
  });
}

Uri? _initialServer(String? saved) {
  final server = serverOrigin(saved ?? '');
  return server;
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() done, {
  int steps = 250,
}) async {
  for (var i = 0; i < steps && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
}
