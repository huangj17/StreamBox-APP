import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/source_health.dart';
import 'package:streambox/data/sources/source_health_checker.dart';

void main() {
  const cmsUrl = 'https://cms.example/api.php/provide/vod/';

  test('CMS 列表正常但 HLS 分片域名指向本机时标记失效', () async {
    final dio = Dio()
      ..httpClientAdapter = _RoutingAdapter((uri) {
        if (uri.host == 'cms.example') {
          return _jsonResponse('''{
            "list":[{
              "vod_id":1,
              "vod_name":"Test",
              "vod_play_from":"line",
              "vod_play_url":"第1集\$https://media.example/index.m3u8"
            }]
          }''');
        }
        if (uri.host == 'media.example') {
          return _textResponse('''#EXTM3U
#EXT-X-TARGETDURATION:3
#EXTINF:3,
https://dead-cdn.example:65/segment0.ts
''', contentType: 'application/vnd.apple.mpegurl');
        }
        throw StateError('Unexpected URL: $uri');
      });
    final checker = SourceHealthChecker(
      dio,
      resolveHost: (host) async => host == 'dead-cdn.example'
          ? [InternetAddress.loopbackIPv4]
          : [InternetAddress('203.0.113.10')],
    );

    final health = await checker.check(cmsUrl);

    expect(health.status, SourceHealthStatus.unavailable);
    expect(health.message, contains('解析到本机或私网'));
  });

  test('CMS HLS 清单、密钥和分片均可读时标记可用', () async {
    final requested = <String>[];
    final dio = Dio()
      ..httpClientAdapter = _RoutingAdapter((uri) {
        requested.add(uri.toString());
        if (uri.host == 'cms.example') {
          return _jsonResponse('''{
            "list":[{
              "vod_id":1,
              "vod_name":"Test",
              "vod_play_from":"line",
              "vod_play_url":"第1集\$https://media.example/index.m3u8"
            }]
          }''');
        }
        if (uri.path.endsWith('index.m3u8')) {
          return _textResponse('''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="enc.key"
#EXTINF:3,
segment0.ts
''', contentType: 'application/vnd.apple.mpegurl');
        }
        if (uri.path.endsWith('enc.key')) {
          return _binaryResponse(List<int>.filled(16, 1));
        }
        if (uri.path.endsWith('segment0.ts')) {
          return _binaryResponse([0x47, 0x40, 0x00, 0x10]);
        }
        throw StateError('Unexpected URL: $uri');
      });
    final checker = SourceHealthChecker(
      dio,
      resolveHost: (_) async => [InternetAddress('203.0.113.10')],
    );

    final health = await checker.check(cmsUrl);

    expect(health.status, SourceHealthStatus.available);
    expect(requested, contains('https://media.example/enc.key'));
    expect(requested, contains('https://media.example/segment0.ts'));
  });

  test('HLS 重定向到本机时在发出下一跳请求前阻止', () async {
    final requested = <Uri>[];
    final dio = Dio()
      ..httpClientAdapter = _RoutingAdapter((uri) {
        requested.add(uri);
        if (uri.host == 'cms.example') {
          return _jsonResponse('''{
            "list":[{
              "vod_id":1,
              "vod_name":"Test",
              "vod_play_from":"line",
              "vod_play_url":"第1集\$https://media.example/index.m3u8"
            }]
          }''');
        }
        if (uri.host == 'media.example') {
          return _redirectResponse('http://127.0.0.1:9978/api/list');
        }
        throw StateError('不应请求重定向目标: $uri');
      });
    final checker = SourceHealthChecker(
      dio,
      resolveHost: (_) async => [InternetAddress('203.0.113.10')],
    );

    final health = await checker.check(cmsUrl);

    expect(health.status, SourceHealthStatus.unavailable);
    expect(health.message, contains('不允许访问本机或私网'));
    expect(requested.every((uri) => uri.host != '127.0.0.1'), isTrue);
  });

  test('无 m3u8 后缀的 HLS variant 仍继续检测实际分片', () async {
    final requested = <Uri>[];
    final dio = Dio()
      ..httpClientAdapter = _RoutingAdapter((uri) {
        requested.add(uri);
        if (uri.host == 'cms.example') {
          return _jsonResponse('''{
            "list":[{
              "vod_id":1,
              "vod_name":"Test",
              "vod_play_from":"line",
              "vod_play_url":"第1集\$https://media.example/master.m3u8"
            }]
          }''');
        }
        if (uri.path == '/master.m3u8') {
          return _textResponse('''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000
variant?token=abc
''', contentType: 'application/vnd.apple.mpegurl');
        }
        if (uri.path == '/variant') {
          return _textResponse('''#EXTM3U
#EXT-X-TARGETDURATION:3
#EXTINF:3,
segment0.ts
''', contentType: 'application/vnd.apple.mpegurl');
        }
        if (uri.path == '/segment0.ts') {
          return _binaryResponse([0x47, 0x40, 0x00, 0x10]);
        }
        throw StateError('Unexpected URL: $uri');
      });
    final checker = SourceHealthChecker(
      dio,
      resolveHost: (_) async => [InternetAddress('203.0.113.10')],
    );

    final health = await checker.check(cmsUrl);

    expect(health.status, SourceHealthStatus.available);
    expect(
      requested.map((uri) => uri.toString()),
      contains('https://media.example/variant?token=abc'),
    );
    expect(
      requested.map((uri) => uri.toString()),
      contains('https://media.example/segment0.ts'),
    );
  });

  test('CMS 有列表但只有网页解析链接时标记待验证', () async {
    final dio = Dio()
      ..httpClientAdapter = _RoutingAdapter(
        (_) => _jsonResponse('''{
          "list":[{
            "vod_id":1,
            "vod_name":"Test",
            "vod_play_from":"line",
            "vod_play_url":"第1集\$https://player.example/watch/123"
          }]
        }'''),
      );
    final checker = SourceHealthChecker(dio);

    final health = await checker.check(cmsUrl);

    expect(health.status, SourceHealthStatus.unverified);
  });

  test('Bridge 只有插件目录正常时标记待验证而非可用', () async {
    final dio = Dio()
      ..httpClientAdapter = _RoutingAdapter(
        (_) => _jsonResponse('''{
          "code":200,
          "sources":[{
            "key":"demo",
            "name":"Demo",
            "api":"/api/demo",
            "kind":"jar",
            "status":"ready"
          }]
        }'''),
      );
    final checker = SourceHealthChecker(dio);

    final health = await checker.check('https://bridge.example:9978');

    expect(health.status, SourceHealthStatus.unverified);
    expect(health.message, contains('播放待验证'));
  });

  test('配置文件只有站点目录正常时标记待验证而非可用', () async {
    final dio = Dio()
      ..httpClientAdapter = _RoutingAdapter(
        (_) => _jsonResponse('''{
          "sites":[{
            "key":"cms",
            "name":"CMS",
            "type":3,
            "api":"https://cms.example/api.php/provide/vod/"
          }]
        }'''),
      );
    final checker = SourceHealthChecker(dio);

    final health = await checker.check('https://config.example/box.json');

    expect(health.status, SourceHealthStatus.unverified);
    expect(health.message, contains('播放待验证'));
  });
}

typedef _Route = ResponseBody Function(Uri uri);

class _RoutingAdapter implements HttpClientAdapter {
  final _Route route;

  _RoutingAdapter(this.route);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => route(options.uri);

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(String value) => ResponseBody.fromString(
  value,
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

ResponseBody _textResponse(String value, {required String contentType}) =>
    ResponseBody.fromString(
      value,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );

ResponseBody _binaryResponse(List<int> value) => ResponseBody(
  Stream.value(Uint8List.fromList(value)),
  206,
  headers: {
    Headers.contentTypeHeader: ['application/octet-stream'],
  },
);

ResponseBody _redirectResponse(String location) => ResponseBody.fromString(
  '',
  302,
  headers: {
    'location': [location],
  },
);
