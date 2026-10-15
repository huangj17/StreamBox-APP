import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/official_source_catalog.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';

const _remote = 'https://9280.kstore.space/wex.json';
const _api = 'https://cms.example/api.php/provide/vod';
const _extra = 'https://extra.example/api.php/provide/vod';
const _other = 'https://other.example/api.php/provide/vod';

Map<String, dynamic> _site(String id, String url, {bool enabled = true}) => {
  'id': id,
  'name': id,
  'url': url,
  'isEnabled': enabled,
};

List<Map<String, dynamic>> _catalog() => [
  {
    'title': '默认片源',
    'data': [_site('a', _api)],
  },
  {'title': '第三方片源', 'data': _remote},
];

String get _defaultGroupUrl =>
    OfficialSourceCatalog.fromJson(_catalog()).groups.first.url;

void main() {
  late Directory temp;
  late SourceStorage storage;
  late _Adapter adapter;
  late Dio dio;
  late SourceLibraryNotifier library;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('grouped-sources-');
    Hive.init(temp.path);
    storage = SourceStorage();
    await storage.init();
    adapter = _Adapter()
      ..documents.addAll({
        SourceStorage.officialUrl: jsonEncode(_catalog()),
        _remote: jsonEncode([
          _site('duplicate', '$_api/'),
          _site('extra', _extra),
        ]),
      });
    dio = Dio()..httpClientAdapter = adapter;
    library = SourceLibraryNotifier(storage, SourceParser(dio));
  });

  tearDown(() async {
    library.dispose();
    dio.close(force: true);
    await Hive.close();
    await temp.delete(recursive: true);
  });

  Future<void> start() async {
    await library.restore();
    await library.refreshAll();
  }

  test('发布文件的每个顶层条目对应一个命名配置源，内嵌重复和 Bridge 仍被过滤', () {
    final catalog = OfficialSourceCatalog.fromJson(
      jsonDecode(File('../deploy/streambox/sources.json').readAsStringSync()),
    );
    expect(catalog.groups.map((g) => g.title), ['默认片源', '第三方片源']);
    expect(catalog.groups.first.config!.sites, hasLength(11));
    expect(catalog.groups.last.url, _remote);
    expect(catalog.groups.last.config, isNull);
    expect(catalog.config.sites.any((s) => s.retiredBridge), isFalse);
    expect(
      OfficialSourceCatalog.fromJson(catalog.toJson()).version,
      catalog.version,
    );
  });

  test('每个分组独立加载；共享接口仅搜索一次并保留两个来源', () async {
    await start();
    expect(library.state.groups.values.map((g) => g.name), ['默认片源', '第三方片源']);
    expect(library.state.groups[_defaultGroupUrl]!.config!.sites, hasLength(1));
    expect(library.state.groups[_remote]!.config!.sites, hasLength(2));
    expect(library.state.activeSites.map((s) => s.identity), [_api, _extra]);
    expect(library.state.originsFor(_api).map((g) => g.name), [
      '默认片源',
      '第三方片源',
    ]);
    expect(adapter.requests, [SourceStorage.officialUrl, _remote]);
    adapter.requests.clear();
    await library.refresh(_remote);
    expect(adapter.requests, [_remote]);
  });

  test('第三方失败与重试只影响自身，失败时保留缓存及名称', () async {
    adapter.failures.add(_remote);
    await start();
    expect(library.state.groups[_defaultGroupUrl]!.error, isNull);
    expect(library.state.groups[_remote]!.error, contains('加载失败'));
    expect(library.state.activeSites.single.identity, _api);
    expect(storage.getOfficialSnapshot(), isNotNull);
    adapter.failures.clear();
    await library.refresh(_remote);
    expect(library.state.groups[_remote]!.error, isNull);
    adapter.failures.add(_remote);
    await library.refreshAll();
    expect(library.state.groups[_remote]!.name, '第三方片源');
    expect(library.state.groups[_remote]!.error, contains('保留已保存的片源'));
    expect(library.state.activeSites, hasLength(2));
  });

  test('重启离线恢复每组缓存、标题、首页及共享开关', () async {
    await start();
    await library.selectHome(library.state.activeSites.last);
    await library.setEnabled(library.state.activeSites.first, false);
    library.dispose();
    await Hive.close();
    await storage.init();
    adapter.failures.addAll(adapter.documents.keys);
    library = SourceLibraryNotifier(storage, SourceParser(dio));
    await library.restore();
    expect(library.state.groups.values.map((g) => g.name), ['默认片源', '第三方片源']);
    expect(library.state.homeIdentity, _extra);
    expect(library.state.activeSites.single.identity, _extra);
    await library.refreshAll();
    expect(library.state.groups[_remote]!.error, isNotNull);
    expect(library.state.activeSites.single.identity, _extra);
  });

  test('远程配置源可移除，更新与重启不会重新添加；可手动恢复', () async {
    await start();
    await library.remove(_remote);
    await library.refreshAll();
    expect(library.state.groups.containsKey(_remote), isFalse);
    library.dispose();
    library = SourceLibraryNotifier(storage, SourceParser(dio));
    await start();
    expect(library.state.groups.containsKey(_remote), isFalse);
    await library.add(_remote);
    expect(library.state.groups[_remote]!.name, '第三方片源');
    expect(library.state.activeSites, hasLength(2));
  });

  test('旧平铺缓存升级分组时保持 key、首页与启用偏好，包括接口换地址', () async {
    final old = OfficialSourceCatalog.fromJson([_site('a', _api)]);
    await storage.saveOfficialSnapshot(
      OfficialSourceSnapshot(old, DateTime.now()),
    );
    await storage.setHomeSite(_api);
    await storage.setSiteEnabled({_api: false});
    adapter.documents[SourceStorage.officialUrl] = jsonEncode([
      {
        'title': '默认片源',
        'data': [_site('a', _other)],
      },
    ]);
    await start();
    final site = library.state.allSites.single;
    expect(site.key, old.config.sites.single.key);
    expect(site.isEnabled, isFalse);
    expect(library.state.homeIdentity, _other);
    expect(storage.getSiteEnabled()[_other], isFalse);
  });

  test('多个内嵌配置分别展示和限制官方停用，远程配置仍支持多仓选择与恢复', () async {
    adapter.documents[SourceStorage.officialUrl] = jsonEncode([
      ..._catalog(),
      {
        'title': '停用片源',
        'data': [_site('off', _other, enabled: false)],
      },
    ]);
    adapter.documents[_remote] = jsonEncode({
      'urls': [
        {'name': '仓库一', 'url': 'https://warehouse.example/one.json'},
      ],
    });
    adapter.documents['https://warehouse.example/one.json'] = jsonEncode([
      _site('extra', _extra),
    ]);
    await start();
    expect(library.state.groups, hasLength(3));
    expect(library.state.groups.values.map((g) => g.name), [
      '默认片源',
      '第三方片源',
      '停用片源',
    ]);
    final off = library.state.allSites.singleWhere((s) => s.identity == _other);
    await library.setEnabled(off, true);
    expect(library.state.isOfficiallyDisabled(_other), isTrue);
    expect(library.state.activeSites.single.identity, _api);
    await library.selectWarehouse(
      _remote,
      'https://warehouse.example/one.json',
    );
    expect(library.state.groups[_remote]!.name, '第三方片源');
    expect(library.state.activeSites.map((s) => s.identity), [_api, _extra]);
    library.dispose();
    library = SourceLibraryNotifier(storage, SourceParser(dio));
    await start();
    expect(
      library.state.groups[_remote]!.warehouseUrl,
      'https://warehouse.example/one.json',
    );
    expect(
      library.state.groups[_remote]!.config!.sites.single.identity,
      _extra,
    );
  });

  test('纯远程目录不额外显示官方片源组；刷新全部每个 URL 只请求一次', () async {
    adapter.documents[SourceStorage.officialUrl] = jsonEncode([
      _catalog().last,
    ]);
    await start();
    expect(library.state.groups.keys, [_remote]);
    adapter.requests.clear();
    await library.refreshAll();
    expect(adapter.requests, [SourceStorage.officialUrl, _remote]);
  });

  test('任何内嵌组停用共享接口后，其他组不会继续将其用于首页或搜索', () async {
    adapter.documents[SourceStorage.officialUrl] = jsonEncode([
      ..._catalog(),
      {
        'title': '共享停用',
        'data': [_site('off', _api, enabled: false)],
      },
    ]);
    await start();
    final shared = library.state.allSites.singleWhere(
      (s) => s.identity == _api,
    );
    expect(shared.isEnabled, isFalse);
    await library.selectHome(shared);
    await library.setEnabled(shared, true);
    expect(library.state.homeIdentity, isNull);
    expect(library.state.activeSites.single.identity, _extra);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    test('远程 TVBox JAR 配置保留运行上下文，按平台显示：$platform', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      adapter.documents[_remote] = jsonEncode({
        'spider': './plugin.jar',
        'sites': [
          {
            'key': 'jar',
            'name': '插件源',
            'api': 'csp_Test',
            'type': 3,
            'ext': './ext.json',
          },
        ],
      });
      await start();
      final site = library.state.groups[_remote]!.config!.sites.single;
      expect(site.configUrl, _remote);
      expect(site.jar, 'https://9280.kstore.space/plugin.jar');
      expect(site.ext, 'https://9280.kstore.space/ext.json');
      expect(
        library.state.allSites.any((s) => s.isJar),
        platform == TargetPlatform.android,
      );
      expect(storage.getCachedConfig(_remote)!.sites.single.jar, site.jar);
    });
  }

  test('更新标题持久化；无效目录不会覆盖快照或添加部分配置', () async {
    await start();
    adapter.documents[SourceStorage.officialUrl] = jsonEncode([
      _catalog().first,
      {'title': '更新的标题', 'data': _remote},
    ]);
    await library.refresh(SourceStorage.officialUrl);
    expect(library.state.groups[_remote]!.name, '更新的标题');
    expect(storage.getName(_remote), '更新的标题');
    final good = storage.getOfficialSnapshot()!.catalog.toJson();
    adapter.documents[SourceStorage.officialUrl] = jsonEncode([
      ..._catalog(),
      {'title': '无效', 'data': 7},
    ]);
    await library.refresh(SourceStorage.officialUrl);
    expect(storage.getOfficialSnapshot()!.catalog.toJson(), good);
    expect(library.state.groups[_remote]!.name, '更新的标题');
  });

  test('分组校验拒绝混合格式、嵌套、重名、重复地址及不合法的 data', () {
    for (final bad in <Object?>[
      {'data': []},
      {'title': '', 'data': []},
      {'title': '错误', 'data': {}},
      {'title': '错误', 'data': null},
      {'title': '默认片源', 'data': []},
      {'title': '重复地址', 'data': _remote},
      {'title': '嵌套', 'data': _catalog()},
      _site('mixed', _extra),
      for (final url in [
        'http://public.example/config.json',
        'https://127.0.0.1/config.json',
        'file:///tmp/a',
        'https://u:p@example.com/a',
      ])
        {'title': '地址', 'data': url},
    ]) {
      expect(
        () => OfficialSourceCatalog.fromJson([..._catalog(), bad]),
        throwsFormatException,
        reason: '$bad',
      );
    }
  });
}

class _Adapter implements HttpClientAdapter {
  final documents = <String, String>{};
  final failures = <String>{};
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
    return ResponseBody.fromString(
      documents[url] ?? '',
      failures.contains(url) ? 503 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
