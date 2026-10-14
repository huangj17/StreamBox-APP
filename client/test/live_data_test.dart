import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/data/live/m3u_parser.dart';
import 'package:streambox/data/live/live_repository.dart';
import 'package:streambox/core/network/bounded_response.dart';
import 'package:streambox/core/network/dio_client.dart';
import 'package:streambox/data/local/live_storage.dart';
import 'package:streambox/data/models/live_channel.dart';
import 'package:streambox/features/live/providers/live_provider.dart';
import 'package:streambox/features/live/live_playback_error.dart';
import 'package:streambox/features/live/live_catalog.dart';
import 'support/fake_live.dart';

void main() {
  test('Playback failure reports cause without signed stream URLs', () {
    const signedUrl = 'https://media.example/live.m3u8?token=private';
    expect(
      livePlaybackErrorMessage('HTTP error 404 $signedUrl', signedUrl),
      contains('已失效'),
    );
    expect(
      livePlaybackErrorMessage('HTTP error 403 $signedUrl', signedUrl),
      contains('拒绝访问'),
    );
    expect(
      livePlaybackErrorMessage(TimeoutException('timeout'), signedUrl),
      contains('连接超时'),
    );
    expect(
      livePlaybackErrorMessage('failed host lookup', signedUrl),
      contains('域名'),
    );
    expect(
      livePlaybackErrorMessage('Failed to open $signedUrl', signedUrl),
      isNot(contains('private')),
    );
    expect(
      livePlaybackErrorMessage(
        'network unreachable',
        'http://[2409:8087::1]/live',
      ),
      contains('IPv6'),
    );
    expect(
      livePlaybackErrorMessage(
        'Failed to open',
        'http://ottrrs.hl.chinamobile.com/live',
      ),
      contains('Guovin'),
    );
  });
  final base = Uri.parse('https://playlist.example/folder/channels.m3u');
  test(
    'M3U: metadata, IPv6 queries, BOM/CRLF, relative URLs and per-channel headers',
    () {
      final parsed = parseLiveM3u(
        '''\ufeff#EXTM3U x-tvg-url="https://epg.example/e.xml"
#EXTINF:-1 tvg-id="cctv1" group-title="央视,高清" tvg-logo="logo.png",CCTV-1 综合
#EXTVLCOPT:http-user-agent=StreamBox
#EXTVLCOPT:http-referrer=https://tv.example/
http://[2409:8087:4c0a:22:1::11]:6410/live/index.m3u8?AuthInfo=a%2Fb
#EXTINF:-1 group-title='卫视频道',卫视
./live.m3u8
'''
            .replaceAll('\n', '\r\n'),
        base: base,
      );
      expect(parsed, hasLength(2));
      expect(parsed.first.group, '央视,高清');
      expect(parsed.first.name, 'CCTV-1 综合');
      expect(parsed.first.tvgId, 'cctv1');
      expect(parsed.first.logo, 'https://playlist.example/folder/logo.png');
      expect(parsed.first.url, contains('?AuthInfo=a%2Fb'));
      expect(parsed.first.headers, {
        'User-Agent': 'StreamBox',
        'Referer': 'https://tv.example/',
      });
      expect(parsed.last.url, 'https://playlist.example/folder/live.m3u8');
      expect(parsed.last.headers, isEmpty);
    },
  );

  test(
    'M3U: missing URLs do not steal next channel; unsafe URLs/duplicates skipped',
    () {
      final parsed = parseLiveM3u('''#EXTM3U
#EXTINF:-1,空频道
#EXTINF:-1,正确频道
https://video.example/live.m3u8
#EXTINF:-1,正确频道
https://video.example/live.m3u8
#EXTINF:-1,本机
http://127.0.0.1/live
#EXTINF:-1,私网
http://192.168.1.1/live
#EXTINF:-1,文件
file:///tmp/video
#EXTINF:-1 tvg-logo="file:///tmp/logo",备用线路
https://video.example/backup
''', base: base);
      expect(parsed.map((c) => c.name), ['正确频道', '备用线路']);
      expect(parsed.last.logo, isNull);
      expect(parsed.first.group, '未分组');
    },
  );

  test(
    'Reject web pages, HLS manifests and playlists without usable channels',
    () {
      for (final text in [
        '<html>error</html>',
        '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\npart.ts',
        '#EXTM3U\n#EXTINF:-1,缺地址',
      ]) {
        expect(() => parseLiveM3u(text, base: base), throwsFormatException);
      }
    },
  );

  test(
    'Subscriptions: duplicate selects existing, errors retain cache, refresh coalesces',
    () async {
      final storage = FakeLiveStorage();
      final repo = FakeLiveRepository();
      final notifier = LiveNotifier(storage, repo);
      addTearDown(notifier.dispose);
      final url = storage.items.first.url;
      final pending = Completer<LivePlaylist>();
      repo.response = (_) => pending.future;
      final first = notifier.refresh(url);
      final second = notifier.refresh(url);
      expect(identical(first, second), isTrue);
      pending.complete(
        LivePlaylist(
          channels: liveChannels(count: 2),
          updatedAt: DateTime.now(),
        ),
      );
      await first;
      await notifier.add('重复 IPv4', url);
      expect(notifier.state.subscriptions, hasLength(2));
      expect(repo.requests, [url]);
      repo.response = (_) => Future.error(const FormatException('没有有效频道'));
      await notifier.refresh(url);
      expect(notifier.state.playlist!.channels, hasLength(2));
      expect(notifier.state.errors[url], '没有有效频道');
      expect(notifier.state.loading, isEmpty);
    },
  );

  test(
    'Remove cancels refresh and ignores a late response even after re-adding URL',
    () async {
      final storage = FakeLiveStorage();
      final repo = FakeLiveRepository();
      final notifier = LiveNotifier(storage, repo);
      addTearDown(notifier.dispose);
      final url = storage.items.first.url;
      final old = Completer<LivePlaylist>();
      repo.response = (_) => old.future;
      final job = notifier.refresh(url);
      await notifier.remove(url);
      expect(repo.tokens.single.isCancelled, isTrue);
      expect(notifier.state.selectedUrl, storage.items.single.url);
      repo.response = (_) => Future.value(
        LivePlaylist(
          channels: liveChannels(count: 1),
          updatedAt: DateTime.now(),
        ),
      );
      await notifier.add('重新添加', url);
      old.complete(
        LivePlaylist(
          channels: liveChannels(count: 5),
          updatedAt: DateTime.now(),
        ),
      );
      await job;
      expect(notifier.state.playlist!.channels, hasLength(1));
      expect(storage.cached(url)!.channels, hasLength(1));
    },
  );

  test('Synchronous fetch failure leaves refresh retryable', () async {
    final repo = FakeLiveRepository()
      ..response = (_) => throw const FormatException('解析失败');
    final notifier = LiveNotifier(FakeLiveStorage(), repo);
    addTearDown(notifier.dispose);
    final url = liveTestSubscriptions.first.url;
    await notifier.refresh(url);
    repo.response = (_) => Future.value(
      LivePlaylist(channels: liveChannels(count: 1), updatedAt: DateTime.now()),
    );
    await notifier.refresh(url);
    expect(repo.requests, hasLength(2));
    expect(notifier.state.playlist!.channels, hasLength(1));
  });

  test(
    'Subscription redirect resolves relative channel against final URI',
    () async {
      final requests = <String>[];
      final dio = Dio()
        ..httpClientAdapter = _LiveAdapter((options) {
          requests.add(options.uri.toString());
          if (requests.length == 1) {
            return ResponseBody.fromString(
              '',
              302,
              headers: {
                'location': ['https://cdn.example/lists/tv.m3u'],
              },
            );
          }
          return ResponseBody.fromString(
            '#EXTM3U\n#EXTINF:-1,频道\n./video/live.m3u8',
            200,
          );
        });
      addTearDown(dio.close);
      final playlist = await LiveRepository(
        dio,
      ).fetch('https://playlist.example/list', cancelToken: CancelToken());
      expect(
        playlist.channels.single.url,
        'https://cdn.example/lists/video/live.m3u8',
      );
      expect(requests, hasLength(2));
    },
  );

  test('Remote subscription cannot redirect to a private service', () async {
    var requests = 0;
    final dio = Dio()
      ..httpClientAdapter = _LiveAdapter((_) {
        requests++;
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://127.0.0.1/internal'],
          },
        );
      });
    addTearDown(dio.close);
    await expectLater(
      LiveRepository(
        dio,
      ).fetch('https://playlist.example/list', cancelToken: CancelToken()),
      throwsFormatException,
    );
    expect(requests, 1);
  });

  test('Subscription bodies have a bounded download size', () async {
    final dio = Dio()
      ..httpClientAdapter = _LiveAdapter(
        (_) => ResponseBody.fromString(
          'body',
          200,
          headers: {
            'content-length': ['6291456'],
          },
        ),
      );
    addTearDown(dio.close);
    await expectLater(
      LiveRepository(
        dio,
      ).fetch('https://playlist.example/list', cancelToken: CancelToken()),
      throwsA(isA<ResponseTooLargeException>()),
    );
  });

  test(
    'Built-in subscription fails over to HTTPS CDN after network failure',
    () async {
      final requests = <Uri>[];
      final dio = createDio()
        ..httpClientAdapter = _LiveAdapter((options) {
          requests.add(options.uri);
          if (options.uri.host == 'raw.githubusercontent.com') {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionTimeout,
            );
          }
          return ResponseBody.fromString(
            '#EXTM3U\n#EXTINF:-1,频道\nhttps://video.example/live.m3u8',
            200,
          );
        });
      addTearDown(dio.close);
      final playlist = await LiveRepository(dio).fetch(
        liveTestRecommendation.url,
        cancelToken: CancelToken(),
        fallbackUrls: liveTestRecommendation.fallbackUrls,
      );
      expect(playlist.channels.single.name, '频道');
      expect(requests.map((u) => u.host), [
        'raw.githubusercontent.com',
        'cdn.jsdelivr.net',
      ]);
      expect(
        requests.last.path,
        '/gh/Guovin/iptv-api@gd/output/ipv4/result.m3u',
      );
    },
  );

  test(
    'Custom subscriptions and explicit HTTP failures do not use another provider',
    () async {
      for (final url in [
        'https://custom.example/list',
        liveTestRecommendation.url,
      ]) {
        var count = 0;
        final dio = Dio()
          ..httpClientAdapter = _LiveAdapter((options) {
            count++;
            if (options.uri.host == 'custom.example') {
              throw DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              );
            }
            return ResponseBody.fromString('Not found', 404);
          });
        await expectLater(
          LiveRepository(dio).fetch(
            url,
            cancelToken: CancelToken(),
            fallbackUrls: url == liveTestRecommendation.url
                ? liveTestRecommendation.fallbackUrls
                : const [],
          ),
          throwsA(isA<DioException>()),
        );
        expect(count, 1);
        dio.close();
      }
    },
  );

  test('Invalid subscription URLs are rejected before requests', () async {
    final repo = FakeLiveRepository();
    final notifier = LiveNotifier(FakeLiveStorage(), repo);
    addTearDown(notifier.dispose);
    await expectLater(
      notifier.add('测试', 'file:///tmp/list.m3u'),
      throwsFormatException,
    );
    await expectLater(
      notifier.add('测试', 'http://remote.example/list.m3u'),
      throwsFormatException,
    );
    expect(repo.requests, isEmpty);
  });

  test(
    'Hive restart retains subscriptions, selection, channels and last channel; deletion persists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'streambox-live-test',
      );
      Hive.init(directory.path);
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      final storage = LiveStorage();
      await storage.init();
      expect(storage.subscriptions, isEmpty);
      await storage.applyCatalog(liveTestCatalog());
      expect(
        storage.subscriptions.map((s) => s.url),
        liveTestCatalog().subscriptions.map((s) => s.url),
      );
      final url = storage.subscriptions.last.url;
      final playlist = LivePlaylist(
        channels: liveChannels(count: 2),
        updatedAt: DateTime.utc(2026, 10, 14),
      );
      await storage.select(url);
      await storage.cache(url, playlist);
      await storage.rememberChannel(url, playlist.channels.last);
      await Hive.close();
      await storage.init();
      expect(storage.selectedUrl, url);
      expect(
        storage.cached(url)!.channels.last.identity,
        playlist.channels.last.identity,
      );
      expect(storage.lastChannel(url), playlist.channels.last.identity);
      expect(storage.lastPlayedUrl, url);
      expect(storage.lastChannelDetails(url)!.url, playlist.channels.last.url);
      await storage.saveSubscriptions([]);
      await storage.select(null);
      await storage.removeCache(url);
      await Hive.close();
      await storage.init();
      expect(storage.subscriptions, isEmpty);
      expect(storage.selectedUrl, isNull);
      expect(storage.cached(url), isNull);
      expect(storage.lastChannel(url), isNull);
      expect(storage.lastPlayedUrl, isNull);
    },
  );

  test(
    'Cold Hive reopen restores watched subscription and station after URL/label changes, with legacy compatibility',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'streambox-live-resume',
      );
      Hive.init(directory.path);
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      final storage = LiveStorage();
      await storage.init();
      await storage.applyCatalog(liveTestCatalog());
      final watchedUrl = liveTestRecommendation.url;
      const watched = LiveChannel(
        name: 'CCTV-6',
        group: '央视频道',
        tvgId: 'cctv6',
        url: 'https://video.example/expired.m3u8?auth=old',
      );
      const updated = LiveChannel(
        name: 'CCTV-6 电影',
        group: '央视频道',
        tvgId: 'cctv6',
        url: 'https://video.example/current.m3u8?auth=new',
      );
      final channels = [liveChannels().first, updated];
      await storage.rememberChannel(watchedUrl, watched);
      await storage.cache(
        watchedUrl,
        LivePlaylist(channels: channels, updatedAt: DateTime.now()),
      );
      // A subscription chosen but never played must not replace actual viewing
      // history on the next app start.
      await storage.select(liveTestSubscriptions[1].url);
      await Hive.close();
      final restarted = LiveStorage();
      await restarted.init();
      final notifier = LiveNotifier(restarted, FakeLiveRepository());
      addTearDown(notifier.dispose);
      expect(notifier.state.selectedUrl, watchedUrl);
      expect(restarted.lastChannelDetails(watchedUrl)!.tvgId, watched.tvgId);
      expect(
        liveResumeIndex(
          notifier.state.playlist!.channels,
          restarted.lastChannelDetails(watchedUrl),
        ),
        1,
      );

      // Existing installations' identity-only records still restore a channel
      // by name/group when that address has expired.
      final box = Hive.box<String>('live_subscriptions');
      await box.put('channel:$watchedUrl', watched.identity);
      final changedUrl = LiveChannel(
        name: watched.name,
        group: watched.group,
        url: updated.url,
      );
      expect(
        liveResumeIndex([
          channels.first,
          changedUrl,
        ], restarted.lastChannelDetails(watchedUrl)),
        1,
      );
      await notifier.remove(watchedUrl);
      expect(restarted.lastPlayedUrl, isNull);
      expect(restarted.lastChannelDetails(watchedUrl), isNull);
    },
  );

  test(
    'Resume prefers the same working line, survives regrouping, and falls back when station was removed',
    () {
      const last = LiveChannel(
        name: 'CCTV-6',
        group: '央视',
        tvgId: 'cctv6',
        url: 'https://video.example/line2',
      );
      final first = liveChannels().first;
      const line1 = LiveChannel(
        name: 'CCTV-6',
        group: '央视',
        tvgId: 'cctv6',
        url: 'https://video.example/line1',
      );
      expect(liveResumeIndex([first, line1, last], last), 2);
      const regrouped = LiveChannel(
        name: 'CCTV-6',
        group: '央视频道',
        tvgId: 'cctv6',
        url: 'https://video.example/new',
      );
      expect(liveResumeIndex([first, regrouped], last), 1);
      expect(liveResumeIndex([first], last), 0);
      const ambiguous = LiveChannel(
        name: 'CCTV-6',
        group: '其他频道',
        tvgId: 'cctv6',
        url: 'https://video.example/other',
      );
      expect(liveResumeIndex([first, regrouped, ambiguous], last), 0);
    },
  );

  test(
    'Upgrade classifies legacy subscriptions without adding embedded defaults or restoring removals',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'streambox-live-upgrade',
      );
      Hive.init(directory.path);
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      final box = await Hive.openBox<String>('live_subscriptions');
      await box.put(
        'subscriptions',
        '[{"name":"IPv4","url":"${liveTestSubscriptions[0].url}"},{"name":"IPv6","url":"${liveTestSubscriptions[1].url}"}]',
      );
      await box.put('selected', liveTestSubscriptions[0].url);
      final storage = LiveStorage();
      await storage.init();
      expect(storage.subscriptions, hasLength(2));
      expect(storage.subscriptions.map((s) => s.id), [
        'ngo5-ipv4',
        'ngo5-ipv6',
      ]);
      expect(storage.hiddenOfficialIds, contains('guovin-ipv4'));
      await storage.applyCatalog(liveTestCatalog());
      expect(storage.subscriptions, hasLength(2));
      expect(storage.selectedUrl, liveTestSubscriptions[0].url);
      await storage.saveSubscriptions(storage.subscriptions.take(2).toList());
      await storage.select(liveTestSubscriptions[0].url);
      await Hive.close();
      await storage.init();
      expect(storage.subscriptions, hasLength(2));
      expect(storage.selectedUrl, liveTestSubscriptions[0].url);
    },
  );

  test(
    'Recommendation upgrade preserves custom selection and an empty subscription list',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'streambox-live-custom',
      );
      Hive.init(directory.path);
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      final box = await Hive.openBox<String>('live_subscriptions');
      await box.put(
        'subscriptions',
        '[{"name":"IPv4","url":"${liveTestSubscriptions[0].url}"},{"name":"Custom","url":"https://custom.example/list"}]',
      );
      await box.put('selected', 'https://custom.example/list');
      final storage = LiveStorage();
      await storage.init();
      expect(storage.selectedUrl, 'https://custom.example/list');
      await storage.saveSubscriptions([]);
      await storage.select(null);
      await box.delete('recommended_ipv4_v1');
      await Hive.close();
      await storage.init();
      expect(storage.subscriptions, isEmpty);
      expect(storage.selectedUrl, isNull);
    },
  );
}

class _LiveAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) respond;
  _LiveAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}
