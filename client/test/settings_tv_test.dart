import 'dart:io';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/source_config.dart';
import 'package:streambox/data/models/source_health.dart';
import 'package:streambox/data/sources/source_health_checker.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/settings/settings_screen.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';
import 'package:streambox/features/source/providers/source_provider.dart';
import 'package:streambox/features/source/source_manage_page.dart';

const _collection = 'https://config.example/OuonnkiTV/lite.json';
final _sites = [
  const Site(
    key: 'red',
    name: '红牛资源',
    type: 3,
    api: 'https://www.hongniuzy2.com/api.php/provide/vod',
  ),
  const Site(
    key: 'storm',
    name: '暴风资源',
    type: 3,
    api: 'https://storm.example/api.php',
  ),
  for (var i = 0; i < 15; i++)
    Site(
      key: 'extra-$i',
      name: '测试片源 $i',
      type: 3,
      api: 'https://source$i.example/api.php',
    ),
];

void main() {
  late Directory temp;
  late SourceStorage storage;
  late _Library library;
  late _Health health;
  late Dio dio;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('settings-tv-');
    Hive.init(temp.path);
    storage = SourceStorage();
    await storage.init();
    dio = Dio();
    library = _Library(
      storage,
      SourceParser(dio),
      SourceLibrary(
        groups: {
          SourceStorage.officialUrl: SourceGroup(
            url: SourceStorage.officialUrl,
            config: SourceConfig(sites: _sites.take(2).toList()),
          ),
          _collection: SourceGroup(
            url: _collection,
            config: SourceConfig(sites: _sites.skip(2).toList()),
          ),
        },
      ),
    );
    health = _Health()
      ..update({for (final site in _sites) site.api: SourceHealth.available()});
  });

  tearDown(() async {
    dio.close(force: true);
    await Hive.close();
    await temp.delete(recursive: true);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    bool settings = true,
    bool routed = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceLibraryProvider.overrideWith((ref) => library),
          sourceHealthProvider.overrideWith((ref) => health),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: routed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      child: const Text('打开设置'),
                    ),
                  ),
                )
              : settings
              ? const SettingsScreen()
              : const SourceManagePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  String? focus() => FocusManager.instance.primaryFocus?.debugLabel;

  void expectFocusedRowVisible() {
    final context = FocusManager.instance.primaryFocus!.context!;
    final row = context.findRenderObject()! as RenderBox;
    final viewport =
        Scrollable.of(context).context.findRenderObject()! as RenderBox;
    final top = row.localToGlobal(Offset.zero, ancestor: viewport).dy;
    expect(top, greaterThanOrEqualTo(0));
    expect(top + row.size.height, lessThanOrEqualTo(viewport.size.height));
  }

  testWidgets('desktop: one click on back exits even when content had focus', (
    tester,
  ) async {
    await pumpPage(tester, routed: true);
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focus(), 'source-group-builtin');
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('打开设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'TV: sidebar, source list, dialog and return keep a continuous focus path',
    (tester) async {
      await pumpPage(tester);
      expect(focus(), 'settings-nav-source');
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'source-group-builtin');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-row-red');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-row-storm');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(Dialog), findsOneWidget);
      expect(focus(), 'source-action-设为首页片源');
      await key(tester, LogicalKeyboardKey.gameButtonB);
      expect(find.byType(Dialog), findsNothing);
      expect(focus(), 'source-row-storm');
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focus(), 'settings-nav-source');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'settings-nav-player');
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'settings-nav-source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: official update is D-pad reachable and keeps focus through loading and failure',
    (tester) async {
      library.pendingOfficialUpdate = Completer<void>();
      library.refreshError = '更新失败，保留上次成功配置';
      await pumpPage(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-row-red');
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focus(), 'source-update');
      await key(tester, LogicalKeyboardKey.select);
      expect(library.officialUpdateRequests, 1);
      expect(find.text('更新中…'), findsOneWidget);
      expect(focus(), 'source-update');
      await key(tester, LogicalKeyboardKey.select);
      expect(library.officialUpdateRequests, 1);
      library.pendingOfficialUpdate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('更新失败，保留上次成功配置'), findsOneWidget);
      expect(find.text('立即更新'), findsOneWidget);
      expect(focus(), 'source-update');
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'settings-nav-source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: remote insertions and reordering keep the focused source visible',
    (tester) async {
      await pumpPage(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-row-storm');
      expectFocusedRowVisible();

      void replaceSites(List<Site> sites) {
        library.replace(
          library.state.copyWith(
            groups: {
              ...library.state.groups,
              SourceStorage.officialUrl: SourceGroup(
                url: SourceStorage.officialUrl,
                config: SourceConfig(sites: sites),
                version: 'v2',
              ),
            },
          ),
        );
      }

      replaceSites([..._sites.skip(2).take(8), ..._sites.take(2)]);
      await tester.pumpAndSettle();
      expect(focus(), 'source-row-storm');
      expectFocusedRowVisible();

      final position = Scrollable.of(
        FocusManager.instance.primaryFocus!.context!,
      ).position;
      final offset = position.pixels;
      health.update({_sites[1].api: SourceHealth.unavailable(message: '超时')});
      await tester.pumpAndSettle();
      expect(position.pixels, offset);

      replaceSites([_sites[1], ..._sites.skip(2).take(8), _sites[0]]);
      await tester.pumpAndSettle();
      expect(focus(), 'source-row-storm');
      expectFocusedRowVisible();

      await key(tester, LogicalKeyboardKey.select);
      final dialogFocus = focus();
      final dialogOffset = position.pixels;
      replaceSites([..._sites.skip(2).take(8), ..._sites.take(2)]);
      await tester.pumpAndSettle();
      expect(focus(), dialogFocus);
      expect(position.pixels, dialogOffset);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'source-row-storm');
      expectFocusedRowVisible();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: remote removal of focused source moves focus to update; empty catalog stays operable',
    (tester) async {
      await pumpPage(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-row-red');
      library.replace(
        SourceLibrary(
          groups: {
            SourceStorage.officialUrl: SourceGroup(
              url: SourceStorage.officialUrl,
              config: const SourceConfig(sites: []),
              version: 'empty-v2',
              syncedAt: DateTime(2026, 9, 2, 20, 10),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('配置版本：empty-v2'), findsOneWidget);
      expect(find.text('这里还没有片源'), findsOneWidget);
      expect(focus(), 'source-update');
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'settings-nav-source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: removal while action dialog is open provides return to a surviving control',
    (tester) async {
      await pumpPage(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(Dialog), findsOneWidget);
      library.replace(
        const SourceLibrary(
          groups: {
            SourceStorage.officialUrl: SourceGroup(
              url: SourceStorage.officialUrl,
              config: SourceConfig(sites: []),
            ),
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('片源已移除'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(Dialog), findsNothing);
      expect(focus(), 'source-update');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: group switching, offscreen rows and health updates preserve focus',
    (tester) async {
      await pumpPage(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'source-action-OuonnkiTV Lite');
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('15 个片源'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-action-检测全部');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-row-extra-0');
      for (var i = 0; i < 10; i++) {
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focus(), 'source-row-extra-10');
      final row = tester.getRect(find.text('测试片源 10'));
      expect(row.top, greaterThan(0));
      expect(row.bottom, lessThan(720));
      health.update({
        _sites[12].api: SourceHealth.unavailable(message: '连接超时'),
      });
      await tester.pumpAndSettle();
      expect(focus(), 'source-row-extra-10');
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('连接超时'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'source-row-extra-10');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: source actions persist and focus remains valid while checking',
    (tester) async {
      await pumpPage(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.enter);
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(library.state.homeIdentity, _sites[1].identity);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(
        library.state.activeSites.any(
          (site) => site.identity == _sites[1].identity,
        ),
        isFalse,
      );
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'source-action-重新检测');
      health.update({_sites[1].api: const SourceHealth.checking()});
      await tester.pumpAndSettle();
      expect(focus(), 'source-action-重新检测');
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'source-row-storm');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: add dialog supports D-pad, validation and focus restoration',
    (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('添加配置源'));
      await tester.pumpAndSettle();
      expect(focus(), 'add-source-input');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'add-source-confirm');
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('请输入完整的 http:// 或 https:// 地址'), findsOneWidget);
      expect(focus(), 'add-source-input');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focus(), 'add-source-cancel');
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focus(), 'add-source-input');
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'add-source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: removing a selected collection restores the surviving group',
    (tester) async {
      await pumpPage(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'source-action-移除');
      await key(tester, LogicalKeyboardKey.enter);
      expect(focus(), 'source-action-保留配置源');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(library.state.groups.containsKey(_collection), isFalse);
      expect(find.text('2 个片源'), findsOneWidget);
      expect(focus(), 'source-group-builtin');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'compact settings: system back returns to the selected menu item',
    (tester) async {
      await pumpPage(tester, size: const Size(390, 844));
      await tester.tap(find.text('配置源管理'));
      await tester.pumpAndSettle();
      expect(find.text('当前首页片源'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('当前首页片源'), findsNothing);
      expect(focus(), 'settings-nav-source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'loading, failure and empty groups retain actions and a return path',
    (tester) async {
      library.replace(
        const SourceLibrary(
          groups: {_collection: SourceGroup(url: _collection, loading: true)},
        ),
      );
      await pumpPage(tester, size: const Size(960, 540));
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('正在加载片源…'), findsOneWidget);
      library.replace(
        const SourceLibrary(
          groups: {
            _collection: SourceGroup(url: _collection, error: '加载失败，请重试'),
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(focus(), 'source-action-OuonnkiTV Lite');
      expect(find.text('更新配置'), findsOneWidget);
      expect(find.text('加载失败，请重试'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'settings-nav-source');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 390.0, 800.0]) {
    testWidgets(
      'touch and keyboard at width $width, enlarged text and keyboard inset',
      (tester) async {
        await pumpPage(
          tester,
          size: Size(width, 844),
          settings: false,
          textScale: 1.3,
        );
        await tester.ensureVisible(find.text('OuonnkiTV Lite'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OuonnkiTV Lite'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('测试片源 0'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('测试片源 0'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        await key(tester, LogicalKeyboardKey.escape);
        await tester.ensureVisible(find.text('添加配置源'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加配置源'));
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await key(tester, LogicalKeyboardKey.arrowDown);
        expect(focus(), 'add-source-confirm');
        expect(tester.getRect(find.text('添加')).bottom, lessThan(544));
        await key(tester, LogicalKeyboardKey.escape);
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

class _Library extends SourceLibraryNotifier {
  Completer<void>? pendingOfficialUpdate;
  String? refreshError;
  int officialUpdateRequests = 0;

  @override
  Future<void> refresh(String url) async {
    if (url != SourceStorage.officialUrl) return super.refresh(url);
    officialUpdateRequests++;
    final previous = state.groups[url]!;
    state = state.copyWith(
      groups: {...state.groups, url: previous.withStatus(loading: true)},
    );
    await pendingOfficialUpdate?.future;
    state = state.copyWith(
      groups: {
        ...state.groups,
        url: previous.withStatus(error: refreshError),
      },
    );
  }

  void replace(SourceLibrary value) {
    state = value;
  }

  _Library(super.storage, super.parser, SourceLibrary initial) {
    state = initial;
  }
  @override
  Future<void> restore() async {}
}

class _Health extends SourceHealthNotifier {
  _Health() : super(SourceHealthChecker(Dio()));
  void update(Map<String, SourceHealth> values) {
    state = {...state, ...values};
  }
}
