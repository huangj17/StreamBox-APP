import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/core/config/production_gateway.dart';
import 'package:streambox/core/network/gateway_auth.dart';
import 'package:streambox/core/network/url_policy.dart';
import 'package:streambox/data/models/official_source_catalog.dart';
import 'package:streambox/data/models/source_health.dart';
import 'package:streambox/data/sources/cms_api.dart';
import 'package:streambox/data/sources/source_health_checker.dart';
import 'package:streambox/data/sources/source_parser.dart';

const _root = ProductionGateway.url;

void main() {
  test('仅原生产端点允许 HTTP，配置、其他插件和相近地址仍受限制', () {
    expect(UrlPolicy.requireGatewayUrl(_root).toString(), _root);
    for (final key in ProductionGateway.pluginKeys) {
      expect(UrlPolicy.isSafeCmsApi('$_root/api/$key'), isTrue);
      expect(UrlPolicy.isSafeCmsApi('$_root/api/$key/play'), isTrue);
    }
    for (final url in [
      'http://1.14.171.39:9979/api/ysj',
      'http://1.14.171.40:9978/api/ysj',
      '$_root/api/doll',
      '$_root/api/list',
      '$_root/proxy',
      '$_root/api/ysj/other',
      '$_root/api/ysj#fragment',
      'http://user@1.14.171.39:9978/api/ysj',
    ]) {
      expect(() => UrlPolicy.requireCmsApiUrl(url), throwsFormatException);
    }
    expect(() => UrlPolicy.requireConfigUrl(_root), throwsFormatException);
    expect(
      () => UrlPolicy.requireGatewayUrl('$_root/proxy'),
      throwsFormatException,
    );
  });

  test('生产请求不携带私有 Gateway Token，私有服务仍可使用 Token', () {
    expect(GatewayAuth.headersFor(Uri.parse('$_root/api/ysj')), isNull);
    expect(
      GatewayAuth.headersFor(Uri.parse('https://private.example')),
      GatewayAuth.headers,
    );
  });

  test('生产目录发现保留原 key，只列出已开放的三个插件', () async {
    final adapter = _Adapter(
      (_) => _json({
        'code': 200,
        'sources': [
          for (final key in [...ProductionGateway.pluginKeys, 'doll'])
            {'key': key, 'name': key, 'api': '/api/$key'},
        ],
      }),
    );
    final config = await SourceParser(_dio(adapter)).parseJarBridge(_root);
    expect(config.sites.map((s) => s.key), [
      'bridge_jianpian',
      'bridge_ikanbot',
      'bridge_ysj',
    ]);
    expect(adapter.requests.single.headers, isNot(contains('Authorization')));
  });

  test('官方片源经过分类、列表、搜索、字符串详情 ID 和剧集解析', () async {
    final site = OfficialSourceCatalog.fromJson([
      {'id': 'bridge_ysj', 'name': '异世界动漫', 'url': '$_root/api/ysj'},
    ]).config.sites.single;
    final adapter = _Adapter((request) {
      expect(request.headers, isNot(contains('Authorization')));
      final query = request.uri.queryParameters;
      if (request.uri.path.endsWith('/play')) {
        expect(query['id'], '1618/sid/1/nid/1.html');
        expect(query['flag'], '主播放线路');
        return _json({
          'parse': 0,
          'url': 'https://media.example/episode.m3u8',
          'header': jsonEncode({'Referer': 'https://anime.example/'}),
        });
      }
      if (query['ac'] == 'class') {
        return _json({
          'class': [
            {'type_id': '', 'type_name': '全部'},
          ],
        });
      }
      if (query.containsKey('ids')) {
        expect(query['ids'], '1618.html');
        return _json({
          'list': [
            {
              'vod_id': '1618.html', 'vod_name': '影片',
              'vod_play_from': '主播放线路',
              // The original Bridge omits parse=1 for relative episode IDs.
              'vod_play_url': r'第1集$1618/sid/1/nid/1.html',
            },
          ],
        });
      }
      expect(query.containsKey('wd') || query['t'] == '', isTrue);
      return _json({
        'list': [
          {'vod_id': '1618.html', 'vod_name': '影片'},
        ],
      });
    });
    final api = CmsApi(_dio(adapter));
    expect((await api.fetchCategories(site)).single.id, '');
    final list = await api.fetchVideoList(site: site, categoryId: '');
    expect(list.items.single.id, '1618.html');
    final result = await api.search(site: site, keyword: '影片');
    final detail = (await api.fetchVideoDetail(
      site: site,
      videoId: result.items.single.id,
    ))!;
    expect(detail.vodId, '1618.html');
    final episode = detail.episodeGroups.single.single;
    expect(episode.requiresResolve, isTrue);
    final play = await api.resolvePlayUrl(
      site: site,
      flag: episode.sourceFlag,
      rawUrl: episode.url,
    );
    expect(play.url, 'https://media.example/episode.m3u8');
    expect(play.headers['Referer'], 'https://anime.example/');
  });

  test('生产 API 与目录逐跳拒绝其他服务、接口和私网', () async {
    for (final location in [
      'http://other.example/api/ysj',
      'https://other.example/api/ysj',
      'http://127.0.0.1:9978/api/ysj',
      '$_root/proxy?url=http://127.0.0.1',
      '$_root/api/jianpian',
    ]) {
      final adapter = _Adapter(
        (_) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': [location],
          },
        ),
      );
      final dio = _dio(adapter);
      final site = SourceParser.wrapCmsUrl('$_root/api/ysj').sites.single;
      await expectLater(
        CmsApi(dio).search(site: site, keyword: '影片'),
        throwsFormatException,
      );
      expect(adapter.requests, hasLength(1));
      adapter.requests.clear();
      expect(await SourceParser(dio).probeGateway(_root), isNull);
      expect(adapter.requests, hasLength(1));
    }
  });

  test('生产 API 接受同端点尾斜杠跳转', () async {
    var count = 0;
    final adapter = _Adapter(
      (_) => count++ == 0
          ? ResponseBody.fromString(
              '',
              302,
              headers: {
                'location': ['$_root/api/ysj/?ac=class'],
              },
            )
          : _json({
              'class': [
                {'type_id': '', 'type_name': '全部'},
              ],
            }),
    );
    final site = SourceParser.wrapCmsUrl('$_root/api/ysj').sites.single;
    expect(await CmsApi(_dio(adapter)).fetchCategories(site), hasLength(1));
    expect(adapter.requests, hasLength(2));
  });

  for (final hasRecommendations in [true, false]) {
    test('生产健康检测先读分类，避免缺少 t 参数返回 500（推荐 $hasRecommendations）', () async {
      final list = [
        {'vod_id': '1618.html', 'vod_name': '影片'},
      ];
      final adapter = _Adapter((request) {
        expect(request.headers, isNot(contains('Authorization')));
        final query = request.uri.queryParameters;
        if (query['ac'] == 'class') {
          return _json({
            'class': [
              {'type_id': '1', 'type_name': '电影'},
            ],
            if (hasRecommendations) 'list': list,
          });
        }
        expect(query, {'ac': 'detail', 't': '1', 'pg': '1'});
        return _json({'list': list});
      });
      final health = await SourceHealthChecker(
        _dio(adapter),
      ).checkCms('$_root/api/jianpian');
      expect(health.status, SourceHealthStatus.unverified);
      expect(adapter.requests, hasLength(hasRecommendations ? 1 : 2));
    });
  }

  test('生产解析仍需网页时返回明确错误，不交给播放器打开网页', () async {
    final adapter = _Adapter(
      (_) =>
          _json({'parse': 1, 'url': 'https://anime.example/watch/1618.html'}),
    );
    final site = SourceParser.wrapCmsUrl('$_root/api/ysj').sites.single;
    await expectLater(
      CmsApi(_dio(adapter)).resolvePlayUrl(
        site: site,
        flag: '主播放线路',
        rawUrl: '1618/sid/1/nid/1.html',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('网页解析'),
        ),
      ),
    );
  });
}

Dio _dio(_Adapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  addTearDown(() => dio.close(force: true));
  return dio;
}

ResponseBody _json(Object body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

class _Adapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  _Adapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}
