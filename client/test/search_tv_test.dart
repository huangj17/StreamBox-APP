import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/cover/cover_resolver.dart';
import 'package:streambox/data/cover/providers.dart';
import 'package:streambox/data/local/search_history_storage.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/video_item.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/search/providers/search_provider.dart';
import 'package:streambox/features/search/search_screen.dart';

const _site = Site(
  key: 'source',
  name: '测试片源',
  type: 3,
  api: 'https://source.example/api',
);
List<VideoItem> videos(int count, {String site = 'source'}) => List.generate(
  count,
  (i) => VideoItem(
    id: '$i',
    title: '测试影片 $i',
    cover: '',
    siteKey: site,
    year: '2026',
  ),
);

void main() {
  late _Search search;
  late _History history;
  late GoRouter router;

  Future<void> pumpSearch(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    String? initialKeyword,
    double textScale = 1,
    Future<List<VideoItem>>? latest,
  }) async {
    search = _Search();
    history = _History();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('首页')),
          routes: [
            GoRoute(
              path: 'search',
              builder: (_, _) => SearchScreen(initialKeyword: initialKeyword),
            ),
            GoRoute(
              path: 'detail',
              builder: (_, _) => const Scaffold(body: Text('详情页')),
            ),
            GoRoute(
              path: 'settings',
              builder: (_, _) => const Scaffold(body: Text('片源设置')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchProvider.overrideWith(() => search),
          searchHistoryStorageProvider.overrideWithValue(history),
          sitesProvider.overrideWith((ref) => [_site]),
          latestUpdatesProvider.overrideWith(
            (ref) => latest ?? Future.value(videos(80)),
          ),
          coverResolverProvider.overrideWithValue(_NoCover()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets(
    'TV: input starts only on OK; grid navigation reaches lazy rows and returns',
    (tester) async {
      await pumpSearch(tester);
      expect(focus(), 'search-query');
      expect(find.byType(TextField), findsNothing);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'search-video-source-0');
      final grid = tester.widget<GridView>(find.byType(GridView));
      final columns =
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount;
      for (var i = 0; i < 8; i++) {
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focus(), 'search-video-source-${columns * 8}');
      expectFocusVisible(tester);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focus(), 'search-query');
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'search-video-source-${columns * 8}');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('详情页'), findsOneWidget);
      router.pop();
      await settle(tester);
      expect(focus(), 'search-video-source-${columns * 8}');
      expectFocusVisible(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'TV: editor supports Chinese input, validation, D-pad and cancel restoration',
    (tester) async {
      await pumpSearch(tester);
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'search-input');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'search-submit');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('先输入想看的影片名称'), findsOneWidget);
      expect(focus(), 'search-input');
      await tester.enterText(find.byType(TextField), ' 庆余年 ');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focus(), 'search-cancel');
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(search.queries, ['庆余年']);
      expect(find.byType(Dialog), findsNothing);
      expect(focus(), 'search-state-action');
      search.complete(videos(12));
      await settle(tester);
      expect(focus(), 'search-video-source-0');
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focus(), 'search-query');
      await key(tester, LogicalKeyboardKey.select);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '庆余年',
      );
      await key(tester, LogicalKeyboardKey.gameButtonB);
      expect(focus(), 'search-query');
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('最近更新'), findsOneWidget);
      expect(focus(), 'search-query');
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.text('首页'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late and incremental results do not steal focus from history or another result',
    (tester) async {
      await pumpSearch(tester, initialKeyword: '沙丘');
      expect(focus(), 'search-state-action');
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focus(), 'search-query');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'search-history-沙丘');
      search.complete(videos(20), completed: 1);
      await settle(tester);
      expect(focus(), 'search-history-沙丘');
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'search-video-source-0');
      await key(tester, LogicalKeyboardKey.arrowDown);
      final focused = focus();
      final offset = Scrollable.of(
        FocusManager.instance.primaryFocus!.context!,
      ).position.pixels;
      search.complete([...videos(20), ...videos(20, site: 'second')]);
      await settle(tester);
      expect(focus(), focused);
      expect(
        Scrollable.of(
          FocusManager.instance.primaryFocus!.context!,
        ).position.pixels,
        offset,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'history management uses OK to delete, retains focus, and handles an empty history',
    (tester) async {
      await pumpSearch(tester);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'search-history-manage');
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'history-delete-庆余年');
      await key(tester, LogicalKeyboardKey.select);
      expect(history.items, ['沙丘', 'Avatar']);
      expect(focus(), 'history-delete-沙丘');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'search-action-清空全部记录');
      await key(tester, LogicalKeyboardKey.select);
      expect(history.items, isEmpty);
      expect(focus(), 'search-history-done');
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'search-history-manage');
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focus(), 'search-query');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'loading, error, retry and zero-source states retain a usable action',
    (tester) async {
      await pumpSearch(tester, initialKeyword: '无结果');
      expect(focus(), 'search-state-action');
      search.fail();
      await settle(tester);
      expect(find.text('暂时无法完成搜索'), findsOneWidget);
      expect(focus(), 'search-state-action');
      await key(tester, LogicalKeyboardKey.select);
      expect(search.queries, ['无结果', '无结果']);
      search.complete([]);
      await settle(tester);
      expect(find.text('没有找到「无结果」'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'search-state-action');
      search.complete([], total: 0);
      await settle(tester);
      expect(find.text('暂无可用的搜索片源'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('片源设置'), findsOneWidget);
      router.pop();
      await settle(tester);
      expect(focus(), 'search-state-action');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recommendations arriving while their loading action is focused restore content focus',
    (tester) async {
      final latest = Completer<List<VideoItem>>();
      await pumpSearch(tester, latest: latest.future);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'search-state-action');
      latest.complete(videos(12));
      await settle(tester);
      expect(focus(), 'search-video-source-0');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(800, 390),
    const Size(960, 540),
  ]) {
    testWidgets('responsive touch input, large text and keyboard at $size', (
      tester,
    ) async {
      await pumpSearch(tester, size: size, textScale: 1.3);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('输入影片名称'));
      await settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), '中文影片');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'search-submit');
      expectFocusVisible(tester, bottom: size.height - 300);
      tester.view.resetViewInsets();
      await key(tester, LogicalKeyboardKey.select);
      search.complete(videos(8));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(focus(), 'search-video-source-0');
      await tester.pumpWidget(const SizedBox());
    });
  }
}

String? focus() => FocusManager.instance.primaryFocus?.debugLabel;
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await settle(tester);
}

void expectFocusVisible(WidgetTester tester, {double? bottom}) {
  final context = FocusManager.instance.primaryFocus!.context!;
  final box = context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(
    rect.bottom,
    lessThanOrEqualTo(bottom ?? tester.view.physicalSize.height),
  );
}

class _Search extends SearchNotifier {
  final queries = <String>[];
  @override
  Future<List<VideoItem>> build() async => [];
  @override
  Future<void> search(String keyword) async {
    queries.add(keyword);
    state = const AsyncLoading();
    ref.read(searchProgressProvider.notifier).state = (completed: 0, total: 2);
    await ref.read(searchHistoryStorageProvider).add(keyword);
    ref.invalidate(searchHistoryProvider);
  }

  void complete(List<VideoItem> items, {int total = 2, int? completed}) {
    ref.read(searchProgressProvider.notifier).state = (
      completed: completed ?? total,
      total: total,
    );
    state = AsyncData(items);
  }

  void fail() {
    state = AsyncError(
      StateError('private network details'),
      StackTrace.current,
    );
  }

  @override
  void clear() {
    state = const AsyncData([]);
    ref.read(searchProgressProvider.notifier).state = (completed: 0, total: 0);
  }
}

class _History extends SearchHistoryStorage {
  final items = ['庆余年', '沙丘', 'Avatar'];
  @override
  List<String> getAll() => List.of(items);
  @override
  Future<void> add(String keyword) async {
    items
      ..remove(keyword)
      ..insert(0, keyword);
  }

  @override
  Future<void> remove(String keyword) async {
    items.remove(keyword);
  }

  @override
  Future<void> clearAll() async {
    items.clear();
  }
}

class _NoCover extends CoverResolver {
  @override
  Future<ResolvedCover?> resolve(String title, String? year) async => null;
}
