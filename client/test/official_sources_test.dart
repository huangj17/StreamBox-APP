import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/core/config/official_sources.dart';
import 'package:streambox/core/network/bounded_response.dart';
import 'package:streambox/core/network/url_policy.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/official_source_catalog.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';

const _url = SourceStorage.officialUrl;
const _apiA = 'https://a.example/api.php';
const _apiB = 'https://b.example/api.php';
Map<String, dynamic> _site(String key, String api, {bool enabled = true}) => {
  'key': key,
  'name': key,
  'type': 3,
  'api': api,
  'isEnabled': enabled,
};
String _document(List<Map<String, dynamic>> sites, {String version = 'v1'}) =>
    jsonEncode({'schemaVersion': 1, 'version': version, 'sites': sites});

void main() {
  late Directory temp;
  late SourceStorage storage;
  late _Adapter adapter;
  late Dio dio;
  late SourceParser parser;
  late SourceLibraryNotifier library;
  late DateTime now;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('official-sources-');
    Hive.init(temp.path);
    storage = SourceStorage();
    await storage.init();
    now = DateTime.utc(2026, 9, 2, 10);
    adapter = _Adapter()
      ..body = _document([_site('a', _apiA), _site('b', _apiB)]);
    dio = Dio()..httpClientAdapter = adapter;
    parser = SourceParser(dio);
    library = SourceLibraryNotifier(storage, parser, now: () => now);
  });

  tearDown(() async {
    library.dispose();
    dio.close(force: true);
    await Hive.close();
    await temp.delete(recursive: true);
  });

  Future<void> start() async {
    await library.restore();
    await library.refresh(
      _url,
    ); // Join the startup request, do not fetch twice.
  }

  test('发布文件与本地兜底兼容，保留旧内置历史 key', () {
    final published = OfficialSourceCatalog.fromJson(
      jsonDecode(File('../deploy/streambox/sources.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    expect(published.config.sites.map((s) => s.api), SourceStorage.builtInUrls);
    expect(
      published.config.sites.map((s) => s.key),
      SourceStorage.builtInUrls.map((url) => url.hashCode.toString()),
    );
  });

  test('HTTP 例外仅用于指定官方地址，不改变普通配置和 CMS 限制', () {
    expect(UrlPolicy.requireOfficialConfigUrl(_url).toString(), _url);
    expect(() => UrlPolicy.requireConfigUrl(_url), throwsFormatException);
    for (final target in [
      'http://1.14.171.39/other.json',
      'http://1.14.171.39:8080/streambox/sources.json',
      'http://1.14.171.39/streambox/sources.json?different=1',
      'http://user:pass@1.14.171.39/streambox/sources.json',
      'http://elsewhere.example/streambox/sources.json',
      'https://127.0.0.1/streambox/sources.json',
      'file:///etc/passwd',
    ]) {
      expect(
        () => UrlPolicy.requireOfficialConfigUrl(target),
        throwsFormatException,
      );
    }
    expect(
      () => UrlPolicy.requireCmsApiUrl('http://a.example/api.php'),
      throwsFormatException,
    );
  });

  test('首次离线使用兜底，联网后整份替换并保留自定义源', () async {
    adapter.status = 503;
    await start();
    expect(
      library.state.activeSites.map((s) => s.api),
      SourceStorage.builtInUrls,
    );
    expect(library.state.groups[_url]!.usingFallback, isTrue);
    expect(storage.getOfficialSnapshot(), isNull);
    await library.add('https://custom.example/api.php');
    adapter.status = 200;
    await library.refresh(_url);
    expect(library.state.activeSites.map((s) => s.api), [
      _apiA,
      _apiB,
      'https://custom.example/api.php',
    ]);
    expect(library.state.groups[_url]!.usingFallback, isFalse);
    expect(library.state.groups[_url]!.version, 'v1');
    expect(library.state.groups[_url]!.syncedAt, now);
    expect(adapter.requests.last.headers['Cache-Control'], 'no-cache');
  });

  test('远程增删、重排、同版本修改与回滚均生效，旧内置源不复活', () async {
    await start();
    adapter.body = _document([_site('b', _apiB), _site('a', _apiA)]);
    await library.refresh(_url);
    expect(library.state.activeSites.map((s) => s.api), [_apiB, _apiA]);
    adapter.body = _document([
      _site('c', 'https://c.example/api.php'),
    ], version: 'v2');
    await library.refresh(_url);
    expect(library.state.activeSites.single.api, 'https://c.example/api.php');
    adapter.body = _document([_site('a', _apiA)], version: 'v1');
    await library.refresh(_url);
    expect(library.state.groups[_url]!.version, 'v1');
    expect(library.state.activeSites.single.api, _apiA);
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), [_url]);
  });

  test('错误 JSON、条目、协议、重复地址和新 schema 均保留最后成功快照', () async {
    await start();
    final good = storage.getOfficialSnapshot()!.catalog.toJson();
    final documents = [
      '<html>nginx</html>',
      '{',
      '[]',
      '{"schemaVersion":1,"version":"missing-sites"}',
      '{"schemaVersion":2,"version":"v2","sites":[]}',
      '{"schemaVersion":1,"version":"","sites":[]}',
      _document([_site('local', 'https://127.0.0.1/api')]),
      _document([_site('http', 'http://public.example/api.php')]),
      _document([_site('script', 'https://public.example/spider.js')]),
      _document([
        {..._site('jar', _apiA), 'type': 4},
      ]),
      _document([
        {..._site('bad', _apiA), 'isEnabled': 'false'},
      ]),
      _document([_site('same', _apiA), _site('same', _apiB)]),
      _document([_site('one', _apiA), _site('two', '$_apiA/')]),
      _document(
        List.generate(201, (i) => _site('s$i', 'https://s$i.example/api')),
      ),
    ];
    for (final document in documents) {
      adapter.body = document;
      await library.refresh(_url);
      expect(library.state.groups[_url]!.error, contains('保留上次成功配置'));
      expect(storage.getOfficialSnapshot()!.catalog.toJson(), good);
      expect(library.state.activeSites.map((s) => s.api), [_apiA, _apiB]);
    }
    adapter.status = 404;
    await library.refresh(_url);
    expect(storage.getOfficialSnapshot()!.catalog.toJson(), good);
  });

  test('空 sites 是明确下架，重启断网也不恢复兜底', () async {
    await start();
    adapter.body = _document([]);
    await library.refresh(_url);
    expect(library.state.activeSites, isEmpty);
    library.dispose();
    await Hive.close();
    await storage.init();
    adapter.status = 503;
    library = SourceLibraryNotifier(storage, parser);
    await start();
    expect(library.state.activeSites, isEmpty);
    expect(library.state.groups[_url]!.usingFallback, isFalse);
  });

  test('有缓存时立即显示；缓存损坏时使用兜底，失败不会覆盖成功时间', () async {
    await start();
    library.dispose();
    adapter.pending = Completer<String>();
    library = SourceLibraryNotifier(storage, parser);
    await library.restore();
    expect(library.state.activeSites.map((s) => s.api), [_apiA, _apiB]);
    expect(library.state.groups[_url]!.loading, isTrue);
    final joined = library.refresh(_url);
    adapter.pending!.complete('invalid');
    await joined;
    adapter.pending = null;
    expect(library.state.groups[_url]!.syncedAt, now);
    library.dispose();
    await Hive.box<String>(
      'source_urls',
    ).put('_official_sources_snapshot_v1', '{broken');
    adapter.status = 503;
    library = SourceLibraryNotifier(storage, parser);
    await start();
    expect(library.state.groups[_url]!.usingFallback, isTrue);
    expect(
      library.state.activeSites.map((s) => s.api),
      SourceStorage.builtInUrls,
    );
  });

  test('用户偏好随稳定 key 换地址，官方停用不能被本地启用覆盖', () async {
    await start();
    final old = library.state.activeSites.first;
    await library.selectHome(old);
    await library.setEnabled(old, false);
    adapter.body = _document([
      _site('a', 'https://new.example/api.php'),
      _site('b', _apiB, enabled: false),
    ]);
    await library.refresh(_url);
    final updated = library.state.allSites.first;
    expect(updated.key, old.key);
    expect(updated.isEnabled, isFalse);
    expect(library.state.homeIdentity, updated.identity);
    expect(storage.getHomeSite(), updated.identity);
    expect(storage.getSiteEnabled()[updated.identity], isFalse);
    await library.setEnabled(library.state.allSites.last, true);
    expect(library.state.activeSites, isEmpty);
  });

  for (final latestEnabled in [true, false]) {
    test('地址回滚保留最新启用偏好 $latestEnabled，并持久化覆盖旧地址记录', () async {
      await start();
      await library.setEnabled(library.state.allSites.first, !latestEnabled);
      adapter.body = _document([
        _site('a', 'https://new.example/api.php'),
        _site('b', _apiB),
      ], version: 'v2');
      await library.refresh(_url);
      await library.setEnabled(library.state.allSites.first, latestEnabled);

      adapter.body = _document([
        _site('a', _apiA),
        _site('b', _apiB),
      ], version: 'v1');
      await library.refresh(_url);
      expect(library.state.allSites.first.isEnabled, latestEnabled);
      expect(storage.getSiteEnabled()[_apiA], latestEnabled);

      library.dispose();
      await Hive.close();
      await storage.init();
      adapter.status = 503;
      library = SourceLibraryNotifier(storage, parser);
      await start();
      expect(library.state.allSites.first.api, _apiA);
      expect(library.state.allSites.first.isEnabled, latestEnabled);
    });
  }

  test('交换地址时从更新前快照迁移启用偏好，不串用其他片源的设置', () async {
    await start();
    await library.setEnabled(library.state.allSites.first, false);
    // B has no explicit preference: its default enabled state must also move.
    adapter.body = _document([_site('a', _apiB), _site('b', _apiA)]);
    await library.refresh(_url);
    expect(library.state.allSites.map((s) => s.isEnabled), [false, true]);
    expect(storage.getSiteEnabled()[_apiB], isFalse);
    expect(storage.getSiteEnabled()[_apiA], isTrue);
  });

  for (final reversed in [false, true]) {
    test('首页随原片源迁移一次，不受地址互换和配置顺序影响（倒序 $reversed）', () async {
      await start();
      final home = library.state.allSites.first;
      await library.selectHome(home);
      final sites = [_site('a', _apiB), _site('b', _apiA)];
      adapter.body = _document(reversed ? sites.reversed.toList() : sites);
      await library.refresh(_url);
      expect(library.state.homeIdentity, _apiB);
      expect(storage.getHomeSite(), _apiB);
      expect(
        library.state.allSites
            .singleWhere((site) => site.identity == library.state.homeIdentity)
            .key,
        home.key,
      );

      library.dispose();
      await Hive.close();
      await storage.init();
      adapter.status = 503;
      library = SourceLibraryNotifier(storage, parser);
      await start();
      expect(library.state.homeIdentity, _apiB);
    });
  }

  test('首页迁移使用下载期间最新的用户选择', () async {
    await start();
    await library.selectHome(library.state.allSites.first);
    adapter.pending = Completer<String>();
    final pending = library.refresh(_url);
    await library.selectHome(library.state.allSites.last);
    adapter.pending!.complete(
      _document([_site('b', _apiA), _site('a', _apiB)]),
    );
    await pending;
    adapter.pending = null;
    expect(library.state.homeIdentity, _apiA);
    expect(storage.getHomeSite(), _apiA);
  });

  test('检查节流包含失败，手动更新绕过间隔，重复请求合并且保留并发偏好修改', () async {
    await start();
    expect(adapter.requests, hasLength(1));
    await library.refreshOfficialIfStale();
    expect(adapter.requests, hasLength(1));
    now = now.add(OfficialSources.refreshInterval);
    adapter.status = 503;
    await library.refreshOfficialIfStale();
    await library.refreshOfficialIfStale();
    expect(adapter.requests, hasLength(2));
    adapter.status = 200;
    adapter.pending = Completer<String>();
    final first = library.refresh(_url);
    final second = library.refresh(_url);
    await library.setEnabled(library.state.allSites.first, false);
    adapter.pending!.complete(adapter.body);
    await Future.wait([first, second]);
    expect(adapter.requests, hasLength(3));
    expect(library.state.allSites.first.isEnabled, isFalse);
    library.setForeground(false);
    now = now.add(OfficialSources.refreshInterval);
    await library.refreshOfficialIfStale();
    expect(adapter.requests, hasLength(3));
    library.setForeground(true);
    await library.refresh(_url);
    expect(adapter.requests, hasLength(4));
  });

  test('官方分组不可移除；dispose 后迟到的结果不写入缓存', () async {
    await start();
    await library.remove(_url);
    expect(library.state.groups, contains(_url));
    adapter.pending = Completer<String>();
    final pending = library.refresh(_url);
    library.dispose();
    adapter.pending!.complete(_document([], version: 'v2'));
    await pending;
    expect(storage.getOfficialSnapshot()!.catalog.version, 'v1');
    library = SourceLibraryNotifier(storage, parser);
  });

  test('重定向逐跳验证，只允许原地址升级到可信 HTTPS', () async {
    for (final location in [
      'http://elsewhere.example/config.json',
      'https://elsewhere.example/config.json',
      'https://127.0.0.1/config.json',
      'http://1.14.171.39/different.json',
    ]) {
      adapter.requests.clear();
      adapter.redirect = location;
      await expectLater(parser.parseOfficialCatalog(), throwsFormatException);
      expect(adapter.requests, hasLength(1));
    }
    adapter.requests.clear();
    adapter.redirect = _url.replaceFirst('http:', 'https:');
    expect((await parser.parseOfficialCatalog()).version, 'v1');
    expect(adapter.requests, hasLength(2));
  });

  test('超大响应不会被缓存', () async {
    adapter.body = ' ' * (256 * 1024 + 1);
    await expectLater(
      parser.parseOfficialCatalog(),
      throwsA(isA<ResponseTooLargeException>()),
    );
    expect(storage.getOfficialSnapshot(), isNull);
  });

  testWidgets('总下载超时会取消挂起的请求', (tester) async {
    adapter.pending = Completer<String>();
    var timedOut = false;
    final pending = parser.parseOfficialCatalog().then<void>(
      (_) {},
      onError: (Object error) {
        timedOut = error is TimeoutException;
      },
    );
    await tester.pump(const Duration(seconds: 21));
    await pending;
    expect(timedOut, isTrue);
    await tester.pump();
    expect(adapter.cancelled, isTrue);
    adapter.pending!.complete(adapter.body);
    await tester.pump();
  });
}

class _Adapter implements HttpClientAdapter {
  String body = '';
  int status = 200;
  String? redirect;
  bool cancelled = false;
  Completer<String>? pending;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    cancelFuture?.then((_) => cancelled = true);
    if (redirect != null && options.uri.scheme == 'http') {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [redirect!],
        },
      );
    }
    return ResponseBody.fromString(
      pending == null ? body : await pending!.future,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
