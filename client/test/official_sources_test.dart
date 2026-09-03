import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/core/config/official_sources.dart';
import 'package:streambox/core/config/production_gateway.dart';
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
Map<String, dynamic> _arraySite(String id, String url, {bool enabled = true}) =>
    {'id': id, 'name': id, 'url': url, 'isEnabled': enabled};

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

  test('服务器端发布示例保留旧内置历史 key', () {
    final published = OfficialSourceCatalog.fromJson(
      jsonDecode(File('../deploy/streambox/sources.json').readAsStringSync()),
    );
    for (final url in SourceStorage.builtInUrls) {
      final site = published.config.sites.singleWhere(
        (s) => s.identity == url.replaceFirst(RegExp(r'/$'), ''),
      );
      expect(site.key, url.hashCode.toString());
    }
    final restored = published.config.sites.where((s) => s.isBridge);
    expect(restored.map((s) => s.key), [
      'bridge_jianpian',
      'bridge_ikanbot',
      'bridge_ysj',
    ]);
    expect(restored.every((s) => s.isSupported), isTrue);
  });

  test('生产片源同属官方列表，保留首页、启停、缓存和历史身份', () async {
    await start();
    await library.selectHome(library.state.allSites.first);
    const production = '${ProductionGateway.url}/api/jianpian';
    adapter.body = jsonEncode([
      _arraySite('a', _apiA),
      _arraySite('bridge_jianpian', production),
    ]);
    await library.refresh(_url);
    expect(library.state.groups.keys, [_url]);
    expect(library.state.homeIdentity, _apiA);
    final restored = library.state.allSites.last;
    expect(restored.key, 'bridge_jianpian');
    expect(restored.isBridge, isTrue);
    await library.selectHome(restored);
    await library.setEnabled(restored, false);

    library.dispose();
    adapter.status = 503;
    library = SourceLibraryNotifier(storage, parser);
    await start();
    expect(library.state.allSites.last.isBridge, isTrue);
    expect(library.state.allSites.last.isEnabled, isFalse);
    expect(library.state.homeIdentity, production);

    adapter.status = 200;
    adapter.body = jsonEncode([
      {
        ..._arraySite('bridge_jianpian', production, enabled: false),
        'searchable': false,
      },
    ]);
    await library.refresh(_url);
    await library.setEnabled(library.state.allSites.single, true);
    expect(library.state.activeSites, isEmpty);
    expect(library.state.allSites.single.searchable, isFalse);
    adapter.body = '[]';
    await library.refresh(_url);
    expect(library.state.allSites, isEmpty, reason: '生产片源也由官方 JSON 管理，不另补内置列表');
  });

  test('上传的 15 条数组片源可同步，HTTP 行不阻塞整份配置且重启可恢复', () async {
    adapter.body = File(
      'test/fixtures/official_sources_array.json',
    ).readAsStringSync();
    await start();
    expect(library.state.groups[_url]!.error, isNull);
    expect(library.state.allSites, hasLength(15));
    expect(library.state.activeSites, hasLength(14));
    expect(library.state.allSites.first.name, '红牛资源');
    expect(library.state.allSites[2].key, 'official:api-guangsuapi-com');
    expect(library.state.allSites.every((site) => site.type == 3), isTrue);
    final unsupported = library.state.allSites.singleWhere(
      (site) => site.name == '电影天堂',
    );
    expect(unsupported.isSupported, isFalse);
    expect(unsupported.api, startsWith('http://'));
    expect(adapter.requests.map((request) => request.uri.toString()), [_url]);
    final snapshot = storage.getOfficialSnapshot()!;
    expect(snapshot.catalog.toJson(), isA<List>());
    expect(snapshot.catalog.version, matches(r'^array-[0-9a-f]{12}$'));
    expect(
      (snapshot.catalog.toJson() as List).first['detailUrl'],
      'https://www.hongniuzy.com',
    );
    await library.selectHome(library.state.activeSites[1]);
    final home = library.state.homeIdentity;
    await library.setEnabled(library.state.allSites.first, false);

    library.dispose();
    await Hive.close();
    await storage.init();
    adapter.status = 503;
    library = SourceLibraryNotifier(storage, parser);
    await start();
    expect(library.state.groups[_url]!.needsInitialSync, isFalse);
    expect(library.state.groups[_url]!.version, snapshot.catalog.version);
    expect(library.state.allSites, hasLength(15));
    expect(library.state.activeSites, hasLength(13));
    expect(library.state.homeIdentity, home);
    expect(library.state.allSites.first.isEnabled, isFalse);
    expect(
      storage.getOfficialSnapshot()!.catalog.toJson(),
      snapshot.catalog.toJson(),
    );
  });

  test('无版本数组按规范化内容生成版本，更新顺序、地址和开关均会变化', () {
    final entries = [_arraySite('a', _apiA), _arraySite('b', _apiB)];
    final original = OfficialSourceCatalog.fromJson(entries);
    final reorderedFields = jsonDecode(
      const JsonEncoder.withIndent('  ').convert([
        for (final entry in entries)
          Map.fromEntries(entry.entries.toList().reversed),
      ]),
    );
    expect(
      OfficialSourceCatalog.fromJson(reorderedFields).version,
      original.version,
    );
    expect(
      OfficialSourceCatalog.fromJson(original.toJson()).version,
      original.version,
    );
    for (final updated in [
      entries.reversed.toList(),
      [_arraySite('a', 'https://new.example/api.php'), entries.last],
      [_arraySite('a', _apiA, enabled: false), entries.last],
      [
        {...entries.first, 'name': '新名称'},
        entries.last,
      ],
    ]) {
      expect(
        OfficialSourceCatalog.fromJson(updated).version,
        isNot(original.version),
      );
    }
    final defaults = OfficialSourceCatalog.fromJson([
      {'id': 'defaults', 'name': '默认片源', 'url': _apiA},
    ]).config.sites.single;
    expect(defaults.isEnabled, isTrue);
    expect(defaults.searchable, isTrue);
    expect(defaults.type, 3);
  });

  test('旧对象和新数组共享稳定 ID，数组换地址、停用和回滚保留用户偏好', () async {
    await start();
    final old = library.state.allSites.first;
    await library.selectHome(old);
    await library.setEnabled(old, false);
    adapter.body = jsonEncode([
      _arraySite('b', _apiB, enabled: false),
      _arraySite('a', 'https://new.example/api.php'),
    ]);
    await library.refresh(_url);
    final updated = library.state.allSites.last;
    expect(updated.key, old.key);
    expect(updated.isEnabled, isFalse);
    expect(library.state.homeIdentity, updated.identity);
    expect(library.state.activeSites, isEmpty);
    await library.setEnabled(library.state.allSites.first, true);
    expect(library.state.activeSites, isEmpty, reason: '官方停用仍优先于本地选择');

    await library.setEnabled(updated, true);
    adapter.body = jsonEncode([
      _arraySite('a', _apiA),
      _arraySite('b', _apiB, enabled: false),
    ]);
    await library.refresh(_url);
    expect(library.state.activeSites.single.identity, _apiA);
    expect(library.state.homeIdentity, _apiA);
    expect(storage.getSiteEnabled()[_apiA], isTrue);
  });

  test('上传格式的红牛 ID 保留旧内置历史 key 和首页偏好', () async {
    await storage.saveOfficialSnapshot(
      OfficialSourceSnapshot(
        OfficialSourceCatalog.fromJson(
          jsonDecode(
            _document([_site('hongniu', SourceStorage.builtInUrls.last)]),
          ),
        ),
        now,
      ),
    );
    adapter.status = 503;
    await start();
    final old = library.state.allSites.last;
    await library.selectHome(old);
    await library.setEnabled(old, false);
    adapter.status = 200;
    adapter.body = jsonEncode([_arraySite('www-hongniuzy-com', _apiA)]);
    await library.refresh(_url);
    final updated = library.state.allSites.single;
    expect(updated.key, old.key);
    expect(updated.isEnabled, isFalse);
    expect(library.state.homeIdentity, _apiA);
    expect(
      storage.getOfficialSnapshot()!.catalog.config.sites.single.key,
      old.key,
    );
  });

  test('数组条目校验失败保留完整旧缓存，不接纳私网、脚本或重复身份', () async {
    adapter.body = jsonEncode([_arraySite('a', _apiA)]);
    await start();
    final good = storage.getOfficialSnapshot()!.catalog.toJson();
    final malformed = <Object?>[
      null,
      1,
      {},
      {'name': '缺少 ID', 'url': _apiB},
      {..._arraySite('b', _apiB), 'name': ''},
      {..._arraySite('b', _apiB), 'id': 'bad id'},
      {..._arraySite('b', _apiB), 'isEnabled': 'false'},
      {..._arraySite('b', _apiB), 'searchable': 1},
      {..._arraySite('b', _apiB), 'detailUrl': {}},
      {..._arraySite('b', _apiB), 'type': 4},
      for (final url in [
        'https://127.0.0.1/api.php',
        'http://192.168.1.1/api.php',
        'http://[::1]/api.php',
        'https://localhost/api.php',
        'https://host.localhost/api.php',
        'file:///etc/passwd',
        'https://user:pass@public.example/api.php',
        'https://public.example/spider.js',
      ])
        _arraySite('b', url),
      _arraySite('a', _apiB),
      _arraySite('b', '$_apiA/'),
    ];
    final documents = [
      for (final bad in malformed) jsonEncode([_arraySite('a', _apiA), bad]),
      jsonEncode(
        List.generate(201, (i) => _arraySite('s$i', 'https://s$i.example/api')),
      ),
      jsonEncode([
        _arraySite('hongniu', _apiA),
        _arraySite('www-hongniuzy-com', _apiB),
      ]),
    ];
    for (final document in documents) {
      adapter.body = document;
      await library.refresh(_url);
      expect(library.state.groups[_url]!.error, isNotNull, reason: document);
      expect(storage.getOfficialSnapshot()!.catalog.toJson(), good);
      expect(library.state.activeSites.single.api, _apiA);
    }
  });

  test('仅含 HTTP 的数组保留不兼容行，不启用、不设为首页、不恢复兜底', () async {
    const api = 'http://public.example/api.php';
    adapter.body = jsonEncode([_arraySite('http', api)]);
    await start();
    final site = library.state.allSites.single;
    expect(site.api, api);
    expect(site.isSupported, isFalse);
    expect(library.state.groups[_url]!.needsInitialSync, isFalse);
    expect(library.state.groups[_url]!.error, isNull);
    await library.setEnabled(site, true);
    await library.selectHome(site);
    expect(library.state.activeSites, isEmpty);
    expect(library.state.homeIdentity, isNull);
    expect(
      storage.getOfficialSnapshot()!.catalog.config.sites.single.isSupported,
      isFalse,
    );
    expect(() => UrlPolicy.requireCmsApiUrl(api), throwsFormatException);
  });

  test('官方配置仅放行指定 HTTP IP，普通订阅和 CMS 仍拒绝公网 HTTP', () {
    expect(_url, 'http://1.14.171.39/streambox/sources.json');
    expect(UrlPolicy.requireOfficialConfigUrl(_url).toString(), _url);
    expect(() => UrlPolicy.requireConfigUrl(_url), throwsFormatException);
    expect(
      UrlPolicy.requireOfficialConfigUrl(
        'https://1.14.171.39/streambox/sources.json',
      ).scheme,
      'https',
    );
    for (final target in [
      'http://stvbox.cloud/streambox/sources.json',
      'https://stvbox.cloud/streambox/sources.json',
      'https://stvbox.cloud/other.json',
      'https://stvbox.cloud:8443/streambox/sources.json',
      'https://stvbox.cloud/streambox/sources.json?different=1',
      'https://user:pass@stvbox.cloud/streambox/sources.json',
      'http://1.14.171.39/other.json',
      'https://1.14.171.39/other.json',
      'http://1.14.171.39:8080/streambox/sources.json',
      'https://1.14.171.39:8443/streambox/sources.json',
      'http://1.14.171.39/streambox/sources.json?different=1',
      'http://1.14.171.39/streambox/sources.json#fragment',
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
    expect(() => UrlPolicy.requireCmsApiUrl(_url), throwsFormatException);
    expect(() => UrlPolicy.requireGatewayUrl(_url), throwsFormatException);
  });

  test('首次离线不注入旧内置源，联网后加载远程列表并保留自定义源', () async {
    adapter.status = 503;
    await start();
    expect(library.state.allSites, isEmpty);
    expect(library.state.groups[_url]!.config, isNull);
    expect(library.state.groups[_url]!.needsInitialSync, isTrue);
    expect(library.state.groups[_url]!.error, contains('暂无本地缓存'));
    expect(storage.getOfficialSnapshot(), isNull);
    await library.add('https://custom.example/api.php');
    await library.selectHome(library.state.activeSites.single);

    library.dispose();
    await Hive.close();
    await storage.init();
    library = SourceLibraryNotifier(storage, parser, now: () => now);
    await start();
    expect(library.state.groups[_url]!.needsInitialSync, isTrue);
    expect(
      library.state.activeSites.single.api,
      'https://custom.example/api.php',
    );
    expect(library.state.homeIdentity, 'https://custom.example/api.php');

    adapter.status = 200;
    await library.refresh(_url);
    expect(library.state.activeSites.map((s) => s.api), [
      _apiA,
      _apiB,
      'https://custom.example/api.php',
    ]);
    expect(library.state.groups[_url]!.needsInitialSync, isFalse);
    expect(library.state.groups[_url]!.version, 'v1');
    expect(library.state.groups[_url]!.syncedAt, now);
    expect(adapter.requests.last.uri.toString(), _url);
    expect(adapter.requests.last.headers['Cache-Control'], 'no-cache');
  });

  test('HTTPS 版升级后只请求 HTTP IP，新地址离线仍立即恢复原缓存', () async {
    const oldUrl = 'https://stvbox.cloud/streambox/sources.json';
    await Hive.box<String>(
      'source_urls',
    ).put('_official_sources_migrated_v1', '1');
    await Hive.box<String>(
      'source_urls',
    ).put('_official_sources_https_migrated_v1', '1');
    await storage.add(oldUrl);
    await storage.setSelected(oldUrl);
    await storage.saveOfficialSnapshot(
      OfficialSourceSnapshot(
        OfficialSourceCatalog.fromJson(
          jsonDecode(adapter.body) as Map<String, dynamic>,
        ),
        now,
      ),
    );
    await storage.setHomeSite(_apiB);
    await storage.setSiteEnabled({_apiA: false});
    adapter.status = 503;

    await start();

    expect(library.state.groups.keys, [_url]);
    expect(adapter.requests.map((r) => r.uri.toString()), [_url]);
    expect(library.state.groups[_url]!.needsInitialSync, isFalse);
    expect(library.state.groups[_url]!.version, 'v1');
    expect(library.state.groups[_url]!.error, contains('保留上次成功配置'));
    expect(library.state.activeSites.single.api, _apiB);
    expect(library.state.homeIdentity, _apiB);
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
      'null',
      'true',
      '123',
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

  for (final emptyDocument in ['[]', _document([])]) {
    test('空列表是明确下架，重启断网也不恢复兜底：$emptyDocument', () async {
      await start();
      adapter.body = emptyDocument;
      await library.refresh(_url);
      expect(library.state.activeSites, isEmpty);
      library.dispose();
      await Hive.close();
      await storage.init();
      adapter.status = 503;
      library = SourceLibraryNotifier(storage, parser);
      await start();
      expect(library.state.activeSites, isEmpty);
      expect(library.state.groups[_url]!.needsInitialSync, isFalse);
    });
  }

  test('有缓存时立即显示；失败不覆盖成功时间，缓存损坏时不补回旧内置源', () async {
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
    expect(library.state.groups[_url]!.needsInitialSync, isTrue);
    expect(library.state.groups[_url]!.error, contains('暂无本地缓存'));
    expect(library.state.allSites, isEmpty);
    expect(storage.getOfficialSnapshot(), isNull);
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

  test('官方重定向逐跳验证，拒绝跳回域名、跨域和路径变更', () async {
    for (final location in [
      'https://stvbox.cloud/streambox/sources.json',
      'http://stvbox.cloud/streambox/sources.json',
      'https://stvbox.cloud/different.json',
      'http://elsewhere.example/config.json',
      'https://elsewhere.example/config.json',
      'https://127.0.0.1/config.json',
      'http://1.14.171.39/different.json',
    ]) {
      adapter.requests.clear();
      adapter.redirects = [location];
      await expectLater(parser.parseOfficialCatalog(), throwsFormatException);
      expect(adapter.requests, hasLength(1));
    }
    adapter.requests.clear();
    adapter.redirects = ['/streambox/sources.json'];
    expect((await parser.parseOfficialCatalog()).version, 'v1');
    expect(adapter.requests, hasLength(2));
  });

  test('允许同 IP 同路径升级到 HTTPS，但之后不能降级回 HTTP', () async {
    const upgraded = 'https://1.14.171.39/streambox/sources.json';
    adapter.redirects = [upgraded];
    expect((await parser.parseOfficialCatalog()).version, 'v1');
    expect(adapter.requests.map((request) => request.uri.toString()), [
      _url,
      upgraded,
    ]);

    adapter.requests.clear();
    adapter.redirects = [upgraded, _url];
    await expectLater(
      parser.parseOfficialCatalog(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('降级'),
        ),
      ),
    );
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
  List<String> redirects = [];
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
    if (requests.length <= redirects.length) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [redirects[requests.length - 1]],
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
