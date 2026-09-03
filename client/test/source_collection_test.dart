import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/official_source_catalog.dart';
import 'package:streambox/data/models/source_health.dart';
import 'package:streambox/data/sources/source_health_checker.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';
import 'package:streambox/features/source/providers/source_provider.dart';
import 'package:streambox/features/source/source_manage_page.dart';

const collection = 'https://config.example/OuonnkiTV/lite.json';
const extraApi = 'https://light.example/api.php/provide/vod';
const fixture = [
  {
    'id': 'red',
    'name': '红牛资源',
    'url': 'https://www.hongniuzy2.com/api.php/provide/vod',
  },
  {'id': 'light', 'name': '光速资源', 'url': extraApi},
  {
    'id': 'duplicate-id',
    'name': '停用源',
    'url': 'https://off.example/api.php',
    'isEnabled': false,
  },
  {
    'id': 'duplicate-id',
    'name': 'HTTP 源',
    'url': 'http://plain.example/api.php',
  },
  {'id': 'trailing-slash', 'name': '重复光速', 'url': '$extraApi/'},
];

void main() {
  late Directory temp;
  late SourceStorage storage;
  late Dio dio;
  late _Adapter adapter;
  late SourceLibraryNotifier library;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('streambox-collection-');
    Hive.init(temp.path);
    storage = SourceStorage();
    await storage.init();
    // Official sources now come only from a successful remote snapshot.
    await storage.saveOfficialSnapshot(
      OfficialSourceSnapshot(
        OfficialSourceCatalog.fromJson(
          jsonDecode(
            File('../deploy/streambox/sources.json').readAsStringSync(),
          ),
        ),
        DateTime.utc(2026, 9, 2),
      ),
    );
    adapter = _Adapter();
    dio = Dio()..httpClientAdapter = adapter;
    library = SourceLibraryNotifier(storage, SourceParser(dio));
    await library.restore();
  });
  tearDown(() async {
    library.dispose();
    dio.close(force: true);
    await Hive.close();
    await temp.delete(recursive: true);
  });

  test('数组兼容、稳定身份、尾斜杠去重和停用标志', () async {
    final parser = SourceParser(dio);
    final result = (await parser.parseDocument(collection)).config!;
    expect(result.sites, hasLength(4));
    expect(result.sites.map((s) => s.key).toSet(), hasLength(4));
    expect(result.sites[2].isEnabled, isFalse);
    expect(result.sites.last.isSupported, isFalse);
    expect(
      SourceParser.isCmsApiUrl('https://api.example/inc/apijson.php'),
      isTrue,
    );
    final id = result.sites[1].key;
    adapter.body = jsonEncode([
      {'id': 'changed', 'name': '新名称', 'url': '$extraApi/'},
    ]);
    expect((await parser.parse(collection)).sites.single.key, id);
  });

  test('原有 TVBox 单仓、多仓和 OuonnkiTV 单对象都可解析', () async {
    final parser = SourceParser(dio);
    adapter.body =
        '{"sites":[{"key":"one","name":"One","api":"$extraApi","type":3}]}';
    expect(
      (await parser.parseDocument(collection)).config!.sites.single.key,
      'one',
    );
    adapter.body =
        '{"urls":[{"name":"仓库","url":"https://warehouse.example/box.json"}]}';
    expect(
      (await parser.parseDocument(collection)).warehouses.single.name,
      '仓库',
    );
    adapter.body = jsonEncode(fixture[1]);
    expect(
      (await parser.parseDocument(collection)).config!.sites.single.name,
      '光速资源',
    );
    adapter.body = '[{"name":"Broken"}]';
    await expectLater(parser.parseDocument(collection), throwsFormatException);
  });

  test('集合与已缓存官方源去重，首页独立选择，停用和缓存可恢复', () async {
    await library.add(collection);
    expect(library.state.allSites, hasLength(5));
    expect(library.state.activeSites, hasLength(3));
    final light = library.state.activeSites.firstWhere(
      (s) => s.api == extraApi,
    );
    await library.selectHome(light);
    await library.setEnabled(light, false);
    expect(library.state.activeSites, hasLength(2));
    expect(storage.getHomeSite(), light.identity);
    expect(storage.getSiteEnabled()[light.identity], isFalse);
    expect(storage.getCachedConfig(collection)!.sites, hasLength(4));

    adapter.body = 'invalid JSON';
    await library.refresh(collection);
    expect(library.state.groups[collection]!.error, contains('保留已保存'));
    expect(library.state.allSites, hasLength(5));
    await Hive.close();
    await storage.init();
    final restored = SourceLibraryNotifier(storage, SourceParser(dio));
    await restored.restore();
    expect(restored.state.homeIdentity, light.identity);
    expect(restored.state.activeSites, hasLength(2));
    restored.dispose();
  });

  test('移除集合后保留共享官方源，迟到的更新不会复活已删除集合', () async {
    await library.add(collection);
    adapter.pending = Completer<String>();
    final refresh = library.refresh(collection);
    await Future<void>.delayed(Duration.zero);
    await library.remove(collection);
    adapter.pending!.complete(jsonEncode(fixture));
    await refresh;
    expect(library.state.groups.containsKey(collection), isFalse);
    expect(library.state.activeSites, hasLength(2));
    expect(storage.getCachedConfig(collection), isNull);
  });

  test('切首页不改变搜索范围，失败源自动回退且不重复刷新首页', () async {
    await library.add(collection);
    final health = _Health();
    final container = ProviderContainer(
      overrides: [
        sourceLibraryProvider.overrideWith(
          (ref) => _LibraryView(library.state, storage, SourceParser(dio)),
        ),
        sourceHealthProvider.overrideWith((ref) => health),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(sitesProvider);
    final light = active.firstWhere((s) => s.api == extraApi);
    final controller = container.read(sourceLibraryProvider.notifier);
    await controller.selectHome(light);
    expect(container.read(homeSitesProvider).single.api, extraApi);
    expect(container.read(searchSitesProvider), hasLength(3));
    var changes = 0;
    container.listen(homeSitesProvider, (_, _) => changes++);
    health.update({active.first.api: SourceHealth.available()});
    expect(container.read(homeSitesProvider).single.api, extraApi);
    expect(changes, 0);
    health.update({extraApi: SourceHealth.unavailable(message: '超时')});
    expect(container.read(homeSitesProvider).single.api, isNot(extraApi));
    expect(container.read(searchSitesProvider), hasLength(2));
    expect(
      container.read(sitesProvider),
      hasLength(3),
      reason: '详情导航仍能找到搜索中的其他源',
    );
  });

  testWidgets('窄屏可切换集合和筛选异常源', (tester) async {
    await tester.runAsync(() => library.add(collection));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final health = _Health()
      ..update({
        for (final site in library.state.allSites)
          site.api: SourceHealth.available(),
      });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceLibraryProvider.overrideWith(
            (ref) => _LibraryView(library.state, storage, SourceParser(dio)),
          ),
          sourceHealthProvider.overrideWith((ref) => health),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const SourceManagePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('OuonnkiTV Lite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OuonnkiTV Lite'));
    await tester.pumpAndSettle();
    expect(find.text('光速资源'), findsOneWidget);
    await tester.ensureVisible(find.text('异常片源（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('异常片源（1）'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('HTTP 源'));
    await tester.pumpAndSettle();
    expect(find.text('暂不兼容'), findsOneWidget);
    expect(find.text('光速资源'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

class _Adapter implements HttpClientAdapter {
  String body = jsonEncode(fixture);
  Completer<String>? pending;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      pending == null ? body : await pending!.future,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Health extends SourceHealthNotifier {
  _Health() : super(SourceHealthChecker(Dio()));
  void update(Map<String, SourceHealth> values) {
    state = values;
  }
}

class _LibraryView extends SourceLibraryNotifier {
  _LibraryView(SourceLibrary initial, super.storage, super.parser) {
    state = initial;
  }
  @override
  Future<void> restore() async {}
}
