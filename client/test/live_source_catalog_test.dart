import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/core/config/live_sources.dart';
import 'package:streambox/core/network/bounded_response.dart';
import 'package:streambox/core/network/url_policy.dart';
import 'package:streambox/data/live/live_repository.dart';
import 'package:streambox/data/local/live_storage.dart';
import 'package:streambox/data/models/live_channel.dart';
import 'package:streambox/data/models/live_source_catalog.dart';
import 'package:streambox/features/live/providers/live_provider.dart';
import 'support/fake_live.dart';

void main() {
  Map<String, dynamic> row(String id, String url, {bool enabled = true}) => {
    'id': id,
    'name': id,
    'url': url,
    'isEnabled': enabled,
  };
  test(
    'Upload artifact has separate endpoint, expected feeds and externally declared download mirrors',
    () {
      final catalog = LiveSourceCatalog.fromJson(
        jsonDecode(
          File('../deploy/streambox/live_sources.json').readAsStringSync(),
        ),
      );
      expect(LiveSources.url, 'http://1.14.171.39/streambox/live_sources.json');
      expect(catalog.subscriptions.map((s) => s.id), [
        'guovin-ipv4',
        'ngo5-ipv4',
        'ngo5-ipv6',
      ]);
      expect(
        catalog.subscriptions.every(
          (s) => s.isEnabled && s.fallbackUrls.length == 1,
        ),
        isTrue,
      );
      expect(
        LiveSourceCatalog.fromJson(catalog.toJson()).subscriptions.first.url,
        liveTestRecommendation.url,
      );
      expect(LiveSourceCatalog.fromJson([]).subscriptions, isEmpty);
    },
  );
  test(
    'Malformed catalogs reject the whole update, including disabled unsafe rows',
    () {
      final valid = row('one', 'https://feed.example/one.m3u');
      for (final input in [
        {},
        [valid, valid],
        [
          valid,
          {...valid, 'id': 'other'},
        ],
        [
          {...valid, 'isEnabled': 'false'},
        ],
        [
          {...valid, 'id': 'bad id'},
        ],
        [
          {...valid, 'url': 'http://feed.example/one', 'isEnabled': false},
        ],
        [
          {...valid, 'url': 'https://127.0.0.1/private'},
        ],
        [
          {...valid, 'url': 'https://192.168.1.1/private'},
        ],
        [
          {
            ...valid,
            'fallbackUrls': ['file:///tmp/live'],
          },
        ],
        [
          {
            ...valid,
            'fallbackUrls': ['https://localhost/internal'],
          },
        ],
        List.generate(201, (i) => row('id$i', 'https://feed.example/$i')),
      ]) {
        expect(() => LiveSourceCatalog.fromJson(input), throwsFormatException);
      }
    },
  );
  test(
    'Catalog requests use pinned endpoint and bounded JSON downloads',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = CatalogAdapter((options) {
          requests.add(options);
          return ResponseBody.fromString(
            jsonEncode([row('one', 'https://feed.example/live.m3u')]),
            200,
          );
        });
      addTearDown(dio.close);
      expect(
        (await LiveRepository(
          dio,
        ).fetchCatalog(cancelToken: CancelToken())).subscriptions.single.id,
        'one',
      );
      expect(requests.single.uri.toString(), LiveSources.url);
      expect(requests.single.extra['skipRetry'], isTrue);
      for (final redirect in [
        'https://127.0.0.1/private',
        'http://stvbox.cloud/streambox/live_sources.json',
        'https://stvbox.cloud/streambox/live_sources.json',
        'http://1.14.171.39/streambox/sources.json',
        'http://1.14.171.39:8080/streambox/live_sources.json',
        'http://1.14.171.40/streambox/live_sources.json',
        'https://1.14.171.39/other/live_sources.json',
      ]) {
        var count = 0;
        dio.httpClientAdapter = CatalogAdapter((_) {
          count++;
          return ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': [redirect],
            },
          );
        });
        await expectLater(
          LiveRepository(dio).fetchCatalog(cancelToken: CancelToken()),
          throwsFormatException,
        );
        expect(count, 1);
      }
      dio.httpClientAdapter = CatalogAdapter(
        (_) => ResponseBody.fromString(
          'too large',
          200,
          headers: {
            'content-length': ['262145'],
          },
        ),
      );
      await expectLater(
        LiveRepository(dio).fetchCatalog(cancelToken: CancelToken()),
        throwsA(isA<ResponseTooLargeException>()),
      );
    },
  );
  test(
    'Only live JSON endpoint may use HTTP; feed and mirror URLs remain HTTPS',
    () {
      expect(
        UrlPolicy.requireLiveConfigUrl(LiveSources.url).toString(),
        LiveSources.url,
      );
      expect(
        UrlPolicy.requireLiveConfigUrl(
          'https://1.14.171.39/streambox/live_sources.json',
        ).scheme,
        'https',
      );
      for (final target in [
        'http://127.0.0.1/streambox/live_sources.json',
        'https://192.168.1.1/streambox/live_sources.json',
        '${LiveSources.url}?other=1',
        '${LiveSources.url}#fragment',
        'http://user:password@1.14.171.39/streambox/live_sources.json',
      ]) {
        expect(
          () => UrlPolicy.requireLiveConfigUrl(target),
          throwsFormatException,
        );
      }
      expect(
        () => requireLiveCatalogUrl(LiveSources.url),
        throwsFormatException,
      );
      expect(
        () => UrlPolicy.requireConfigUrl(LiveSources.url),
        throwsFormatException,
      );
      expect(
        () => LiveSourceCatalog.fromJson([row('one', LiveSources.url)]),
        throwsFormatException,
      );
      expect(
        () => LiveSourceCatalog.fromJson([
          {
            ...row('one', 'https://feed.example/live.m3u'),
            'fallbackUrls': [LiveSources.url],
          },
        ]),
        throwsFormatException,
      );
    },
  );
  test(
    'Live JSON may upgrade same endpoint to HTTPS but cannot downgrade after upgrade',
    () async {
      const upgraded = 'https://1.14.171.39/streambox/live_sources.json';
      for (final downgrade in [false, true]) {
        final requests = <String>[];
        final dio = Dio()
          ..httpClientAdapter = CatalogAdapter((options) {
            requests.add(options.uri.toString());
            if (requests.length == 1 || downgrade) {
              return ResponseBody.fromString(
                '',
                302,
                headers: {
                  'location': [
                    requests.length == 1 ? upgraded : LiveSources.url,
                  ],
                },
              );
            }
            return ResponseBody.fromString(
              jsonEncode([row('one', 'https://feed.example/live.m3u')]),
              200,
            );
          });
        addTearDown(dio.close);
        final request = LiveRepository(
          dio,
        ).fetchCatalog(cancelToken: CancelToken());
        if (downgrade) {
          await expectLater(request, throwsFormatException);
        } else {
          expect((await request).subscriptions.single.id, 'one');
        }
        expect(requests, [LiveSources.url, upgraded]);
      }
    },
  );
  test(
    'Sync coalesces, merges concurrent custom additions, caches failures and honours removal/restore',
    () async {
      final storage = FakeLiveStorage()
        ..items = []
        ..selection = null;
      final repository = FakeLiveRepository();
      final pending = Completer<LiveSourceCatalog>();
      repository.catalogResponse = () => pending.future;
      final notifier = LiveNotifier(storage, repository);
      addTearDown(notifier.dispose);
      final sync = notifier.syncCatalog(force: true);
      final same = notifier.syncCatalog(force: true);
      expect(identical(sync, same), isTrue);
      await notifier.add('Custom', 'https://custom.example/live.m3u');
      pending.complete(liveTestCatalog());
      await sync;
      expect(notifier.state.subscriptions, hasLength(4));
      expect(notifier.state.selectedUrl, 'https://custom.example/live.m3u');
      final official = notifier.state.subscriptions.first;
      await notifier.remove(official.url);
      repository.catalogResponse = () => Future.value(liveTestCatalog());
      await notifier.syncCatalog(force: true);
      expect(
        notifier.state.subscriptions.any((s) => s.id == official.id),
        isFalse,
      );
      await notifier.restoreOfficial();
      expect(
        notifier.state.subscriptions.any((s) => s.id == official.id),
        isTrue,
      );
      final old = notifier.state.subscriptions.map((s) => s.url).toList();
      repository.catalogResponse = () =>
          Future.error(const FormatException('bad JSON'));
      await notifier.syncCatalog(force: true);
      expect(notifier.state.subscriptions.map((s) => s.url), old);
      expect(notifier.state.catalogError, contains('继续使用缓存'));
      expect(notifier.state.catalogLoading, isFalse);
    },
  );
  test(
    'Empty and disabled server lists remove only official subscriptions; late channel responses are ignored',
    () async {
      final storage = FakeLiveStorage()
        ..items = [...liveTestCatalog().subscriptions]
        ..selection = liveTestRecommendation.url;
      final repository = FakeLiveRepository();
      final channelLoad = Completer<LivePlaylist>();
      repository.response = (_) => channelLoad.future;
      repository.catalogResponse = () =>
          Future.value(LiveSourceCatalog.fromJson([]));
      final notifier = LiveNotifier(storage, repository);
      addTearDown(notifier.dispose);
      final old = notifier.refresh(liveTestRecommendation.url);
      await notifier.syncCatalog(force: true);
      expect(notifier.state.subscriptions, isEmpty);
      expect(notifier.state.selectedUrl, isNull);
      expect(repository.tokens.single.isCancelled, isTrue);
      channelLoad.complete(
        LivePlaylist(channels: liveChannels(), updatedAt: DateTime.now()),
      );
      await old;
      expect(notifier.state.playlists, isEmpty);
      await notifier.add('Custom', 'https://custom.example/live.m3u');
      repository.catalogResponse = () => Future.value(
        LiveSourceCatalog.fromJson([
          row('one', 'https://feed.example/one', enabled: false),
        ]),
      );
      await notifier.syncCatalog(force: true);
      expect(notifier.state.subscriptions.single.name, 'Custom');
    },
  );
  test(
    'Hive caches catalog, migrates stable-ID address swaps/history, preserves custom data and deletions across restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('streambox-live-json');
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });
      final storage = LiveStorage();
      await storage.init();
      expect(storage.subscriptions, isEmpty);
      final one = 'https://feed.example/one';
      final two = 'https://feed.example/two';
      await storage.applyCatalog(
        LiveSourceCatalog.fromJson([row('a', one), row('b', two)]),
      );
      final a = liveChannels(count: 1).single;
      final b = liveChannels(count: 2).last;
      await storage.cache(
        one,
        LivePlaylist(channels: [a], updatedAt: DateTime.now()),
      );
      await storage.cache(
        two,
        LivePlaylist(channels: [b], updatedAt: DateTime.now()),
      );
      await storage.rememberChannel(one, a);
      await storage.rememberChannel(two, b);
      await storage.select(one);
      const custom = LiveSubscription(
        name: 'Custom',
        url: 'https://custom.example/list',
      );
      await storage.saveSubscriptions([...storage.subscriptions, custom]);
      await storage.applyCatalog(
        LiveSourceCatalog.fromJson([row('a', two), row('b', one)]),
        currentSelected: one,
      );
      expect(storage.selectedUrl, two);
      expect(storage.lastPlayedUrl, one);
      expect(storage.lastChannel(two), a.identity);
      expect(storage.lastChannel(one), b.identity);
      expect(storage.cached(two)!.channels.single.identity, a.identity);
      expect(storage.cached(two)!.updatedAt.millisecondsSinceEpoch, 0);
      expect(storage.cached(one)!.channels.single.identity, b.identity);
      await storage.hideOfficial('a');
      await storage.applyCatalog(
        LiveSourceCatalog.fromJson([row('a', two), row('b', one)]),
      );
      await Hive.close();
      final restarted = LiveStorage();
      await restarted.init();
      expect(restarted.subscriptions.map((s) => s.id), ['b', null]);
      expect(restarted.hiddenOfficialIds, contains('a'));
      expect(restarted.officialCatalog!.subscriptions, hasLength(2));
      expect(restarted.officialSyncedAt, isNotNull);
      await restarted.applyCatalog(LiveSourceCatalog.fromJson([]));
      expect(restarted.subscriptions.single.url, custom.url);
      await restarted.restoreOfficial();
      await restarted.applyCatalog(LiveSourceCatalog.fromJson([row('a', two)]));
      expect(restarted.subscriptions.map((s) => s.id), ['a', null]);
    },
  );
  test(
    'Remote address changes never take over a user-owned old endpoint',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'streambox-live-json-custom',
      );
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });
      final storage = LiveStorage();
      await storage.init();
      const old = 'https://feed.example/old';
      const updated = 'https://feed.example/new';
      await storage.applyCatalog(LiveSourceCatalog.fromJson([row('a', old)]));
      final watched = liveChannels().last;
      await storage.rememberChannel(old, watched);
      await storage.applyCatalog(
        LiveSourceCatalog.fromJson([row('a', old, enabled: false)]),
      );
      await storage.saveSubscriptions([
        const LiveSubscription(name: 'Custom', url: old),
      ]);
      await storage.select(old);
      await storage.applyCatalog(
        LiveSourceCatalog.fromJson([row('a', updated)]),
        currentSelected: old,
      );
      expect(storage.selectedUrl, old);
      expect(storage.lastPlayedUrl, old);
      expect(storage.lastChannel(old), watched.identity);
      expect(storage.subscriptions.last.id, isNull);
    },
  );

  testWidgets(
    'Catalog auto refresh runs only in foreground and disposes its timer',
    (tester) async {
      final storage = FakeLiveStorage()
        ..items = []
        ..selection = null;
      var count = 0;
      final repository = FakeLiveRepository()
        ..catalogResponse = () {
          count++;
          return Future.value(LiveSourceCatalog.fromJson([]));
        };
      final notifier = LiveNotifier(storage, repository);
      notifier.setForeground(true);
      await tester.pump();
      expect(count, 1);
      await tester.pump(const Duration(minutes: 30));
      await tester.pump();
      expect(count, 2);
      notifier.setForeground(false);
      await tester.pump(const Duration(minutes: 30));
      expect(count, 2);
      notifier.setForeground(true);
      await tester.pump(const Duration(minutes: 30));
      await tester.pump();
      expect(count, 3);
      notifier.dispose();
    },
  );

  test(
    'Dispose cancels a pending catalog request and ignores its late result',
    () async {
      final storage = FakeLiveStorage()..items = [];
      final pending = Completer<LiveSourceCatalog>();
      final repository = FakeLiveRepository()
        ..catalogResponse = () => pending.future;
      final notifier = LiveNotifier(storage, repository);
      final job = notifier.syncCatalog(force: true);
      notifier.dispose();
      expect(repository.catalogTokens.single.isCancelled, isTrue);
      pending.complete(liveTestCatalog());
      await job;
      expect(storage.items, isEmpty);
    },
  );
}

class CatalogAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) respond;
  CatalogAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}
