import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/core/network/url_policy.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/source_config.dart';
import 'package:streambox/data/sources/android_spider_client.dart';
import 'package:streambox/data/sources/cms_api.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';

const configUrl = 'https://config.example/box/m.json';
SourceConfig bundle() => SourceConfig.fromJson({
  'spider': './plugin.jpg;md5;0123456789abcdef0123456789abcdef',
  'sites': [
    {
      'key': 'one',
      'name': 'One',
      'type': 3,
      'api': 'csp_App',
      'ext': {'config': 'a'},
    },
    {
      'key': 'two',
      'name': 'Two',
      'type': 3,
      'api': 'csp_App',
      'ext': {'config': 'b'},
      'jar': './other.jar',
    },
    {
      'key': 'cms',
      'name': 'CMS',
      'type': 1,
      'api': 'https://cms.example/api.php',
    },
  ],
}, configUrl: configUrl);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    UrlPolicy.clearAndroidProxy();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidSpiderClient.channel, null);
  });

  test(
    'CMS remains visible everywhere; native JAR is visible only on Android',
    () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final library = SourceLibrary(
          groups: {configUrl: SourceGroup(url: configUrl, config: bundle())},
        );
        expect(
          library.allSites.map((s) => s.key),
          platform == TargetPlatform.android ? ['one', 'two', 'cms'] : ['cms'],
        );
        expect(
          library.activeSites,
          hasLength(platform == TargetPlatform.android ? 3 : 1),
        );
      }
    },
  );

  test(
    'shared csp class keeps separate identities and ext through cache serialization',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final config = bundle();
      expect(config.sites[0].identity, isNot(config.sites[1].identity));
      expect(
        config.sites.first.jar,
        'https://config.example/box/plugin.jpg;md5;0123456789abcdef0123456789abcdef',
      );
      expect(config.sites[1].jar, 'https://config.example/box/other.jar');
      final renamed = config.sites.first.copyWith(key: 'renamed-key');
      final cached = Site.fromCache(jsonDecode(jsonEncode(renamed.toJson())));
      expect(cached.identity, config.sites.first.identity);
      expect(cached.ext, {'config': 'a'});
      expect(cached.configUrl, configUrl);
      expect(cached.jar, config.sites.first.jar);
    },
  );

  test(
    'JSON comments and trailing commas preserve quoted URLs and escapes',
    () {
      final decoded =
          decodeSourceJson(r'''
      // TVBox comment
      {"spider":"./a.jar", "url":"https://example.com/a//b?x=/*quoted*/",
       "escaped":"a\"//b", /* comment */ "sites":[{"key":"one",},],}
    ''')
              as Map<String, dynamic>;
      expect(decoded['url'], 'https://example.com/a//b?x=/*quoted*/');
      expect(decoded['escaped'], 'a"//b');
      expect((decoded['sites'] as List).single, {'key': 'one'});
      expect(() => decodeSourceJson('{/* missing'), throwsFormatException);
    },
  );

  test(
    'configuration resolves relative JAR, script and ext references without executing them',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter('''// comment
      {"spider":"./p.jar", "sites":[
      {"key":"one","name":"One","type":3,"api":"csp_App","ext":"./data.json"},
      {"key":"js","name":"JS","type":3,"api":"./rule.js"}]}''');
      final config = (await SourceParser(dio).parseDocument(configUrl)).config!;
      expect(config.sites.first.ext, 'https://config.example/box/data.json');
      expect(config.sites.last.api, 'https://config.example/box/rule.js');
      expect(config.sites.last.isSupported, isFalse);
    },
  );

  test(
    'all native data operations use the channel and every episode is resolved',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidSpiderClient.channel, (call) async {
            calls.add(call);
            final args = Map<String, dynamic>.from(call.arguments as Map);
            final site = Map<String, dynamic>.from(args['site'] as Map);
            expect(site['ext'], {'config': 'a'});
            expect(
              site['jar'],
              startsWith('https://config.example/box/plugin.jpg'),
            );
            final body = switch (args['method']) {
              'home' => {
                'class': [
                  {'type_id': '1', 'type_name': 'Movie'},
                ],
              },
              'category' || 'search' => {
                'list': [
                  {'vod_id': 'slug', 'vod_name': 'Movie'},
                ],
              },
              'detail' => {
                'list': [
                  {
                    'vod_id': 'slug',
                    'vod_name': 'Movie',
                    'vod_play_from': 'HD',
                    'vod_play_url': r'Episode$https://site.example/watch/slug',
                  },
                ],
              },
              'play' => {
                'parse': 0,
                'url': 'https://media.example/video.m3u8',
                'header': {'Referer': 'https://site.example/'},
              },
              _ => throw StateError('unexpected method'),
            };
            return {
              'data': jsonEncode(body),
              'proxyOrigin':
                  'http://127.0.0.1:12345/spider/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
            };
          });
      final site = bundle().sites.first;
      final api = CmsApi(Dio()..httpClientAdapter = _Adapter(null));
      expect((await api.fetchCategories(site)).single.name, 'Movie');
      expect(
        (await api.fetchVideoList(site: site, categoryId: '1')).items.single.id,
        'slug',
      );
      final detail = (await api.fetchVideoDetail(site: site, videoId: 'slug'))!;
      expect(detail.episodeGroups.single.single.requiresResolve, isTrue);
      await api.search(site: site, keyword: 'Movie');
      final play = await api.resolvePlayUrl(
        site: site,
        flag: 'HD',
        rawUrl: 'https://site.example/watch/slug',
      );
      expect(play.url, 'https://media.example/video.m3u8');
      expect(play.headers['Referer'], 'https://site.example/');
      expect(calls.map((c) => (c.arguments as Map)['method']), [
        'home',
        'category',
        'detail',
        'search',
        'play',
      ]);
    },
  );

  test(
    'non-Android refuses direct plugin calls before contacting any host',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final api = CmsApi(Dio()..httpClientAdapter = _Adapter(null));
      await expectLater(
        api.fetchCategories(bundle().sites.first),
        throwsFormatException,
      );
      await expectLater(
        api.resolvePlayUrl(
          site: bundle().sites.first,
          flag: 'HD',
          rawUrl: 'id',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'only the native host-issued proxy origin and token path allow local playback',
    () {
      expect(
        () => UrlPolicy.requirePlaybackUrl('http://127.0.0.1:12345/proxy'),
        throwsFormatException,
      );
      expect(
        () => UrlPolicy.registerAndroidProxy(
          'http://192.168.1.1:12345/spider/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
        ),
        throwsFormatException,
      );
      UrlPolicy.registerAndroidProxy(
        'http://127.0.0.1:12345/spider/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
      );
      expect(
        UrlPolicy.requirePlaybackUrl(
          'http://127.0.0.1:12345/spider/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/site/key/proxy',
        ).port,
        12345,
      );
      expect(
        () => UrlPolicy.requirePlaybackUrl(
          'http://127.0.0.1:12345/spider/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/proxy',
        ),
        throwsFormatException,
      );
      expect(
        () => UrlPolicy.requirePlaybackUrl(
          'http://127.0.0.1:12346/spider/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/proxy',
        ),
        throwsFormatException,
      );
    },
  );
}

class _Adapter implements HttpClientAdapter {
  final String? body;
  _Adapter(this.body);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (body == null) {
      throw StateError('native source must not make CMS requests');
    }
    return ResponseBody.fromString(
      body!,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
