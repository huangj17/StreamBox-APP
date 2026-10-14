import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/cover/cover_resolver.dart';
import 'package:streambox/data/cover/providers.dart';
import 'package:streambox/data/local/favorite_storage.dart';
import 'package:streambox/data/local/history_storage.dart';
import 'package:streambox/data/models/cms_video_detail.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/video_item.dart';
import 'package:streambox/data/models/watch_history.dart';
import 'package:streambox/data/models/playback_resume.dart';
import 'package:streambox/data/sources/cms_api.dart';
import 'package:streambox/features/detail/aggregate_detail_screen.dart';
import 'package:streambox/features/detail/providers/aggregate_detail_provider.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';

const a = Site(key: 'a', name: '片源甲', type: 3, api: 'https://a.example/api');
const b = Site(key: 'b', name: '片源乙', type: 3, api: 'https://b.example/api');
const va = VideoItem(
  id: 'a-video',
  title: '沙丘',
  cover: '',
  siteKey: 'a',
  year: '2021',
);
const vb = VideoItem(
  id: 'b-video',
  title: '沙丘',
  cover: '',
  siteKey: 'b',
  year: '2021',
);

ResolvedVideoSource resolved(
  Site site,
  VideoItem video, {
  bool emptyFirst = false,
  List<List<String>>? names,
}) => ResolvedVideoSource(
  video: video,
  site: site,
  sourceScore: site == b ? 20 : 0,
  responseMs: 100,
  detail: CmsVideoDetail(
    vodId: video.id,
    vodName: video.title,
    vodPic: '',
    vodContent: '',
    vodYear: '2021',
    vodPlayFrom: names != null
        ? List.generate(names.length, (i) => 'line$i').join(r'$$$')
        : emptyFirst
        ? r'empty$$$main'
        : '1080p',
    vodPlayUrl: names != null
        ? names
              .asMap()
              .entries
              .map(
                (group) => group.value
                    .asMap()
                    .entries
                    .map(
                      (ep) =>
                          '${ep.value}\$https://1.1.1.1/${group.key}/${ep.key}.m3u8',
                    )
                    .join('#'),
              )
              .join(r'$$$')
        : emptyFirst
        ? r'空线路$$$第01集$https://1.1.1.1/movie.m3u8'
        : r'第01集$https://1.1.1.1/movie.m3u8',
  ),
);

void main() {
  for (final position in [123456, 0]) {
    testWidgets('TV: 跨源按名称定位第5集并保留 $position 毫秒，覆盖目标旧记录', (tester) async {
      final state = AggregateDetailState(
        candidates: [va, vb],
        resolved: [
          resolved(
            a,
            va,
            names: [
              ['第1集', '第2集', '第3集', '第4集', '第05集'],
            ],
          ),
          resolved(
            b,
            vb,
            names: [
              ['第1集', '第2集'],
              ['第6集', 'EP5', '第2集'],
            ],
          ),
        ],
        completed: 2,
        initialSelection: 'a:a-video',
      );
      final history = _History([
        watch(va, '第05集', position, episode: 4),
        watch(vb, '第1集', 999999),
      ]);
      Map<String, dynamic>? played;
      final router = await pumpDetail(
        tester,
        state,
        history: history,
        onPlay: (data) => played = data,
      );
      expect(focus(), 'detail-play');
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'detail-source-switch');
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      await tester.pump(const Duration(seconds: 2));
      expect(focus(), 'detail-source-switch');
      expect(find.text('当前片源：片源乙'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.select);
      expect(played!['initialGroupIndex'], 1);
      expect(played!['initialEpisodeIndex'], 1);
      expect(played!['initialPositionMs'], position);
      expect(played!['videoId'], 'b-video');
      router.pop(
        const PlaybackResume(
          episodeName: 'EP5',
          groupIndex: 1,
          episodeIndex: 1,
          positionMs: 200123,
        ),
      );
      await settle(tester);
      expect(find.textContaining('继续 EP5 3:20'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.select);
      await tester.pump(const Duration(seconds: 2));
      await key(tester, LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.select);
      expect(played!['initialEpisodeIndex'], 4);
      expect(played!['initialPositionMs'], 200123);
      expect(played!['videoId'], 'a-video');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('TV: 目标片源缺少当前集时保留原选择、进度和切源焦点', (tester) async {
    final state = AggregateDetailState(
      candidates: [va, vb],
      resolved: [
        resolved(
          a,
          va,
          names: [
            ['第1集', '第05集'],
          ],
        ),
        resolved(
          b,
          vb,
          names: [
            ['第1集', '第2集'],
          ],
        ),
      ],
      completed: 2,
      initialSelection: 'a:a-video',
    );
    Map<String, dynamic>? played;
    await pumpDetail(
      tester,
      state,
      history: _History([watch(va, '第05集', 77777, episode: 1)]),
      onPlay: (data) => played = data,
    );
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('当前片源：片源甲'), findsOneWidget);
    expect(find.textContaining('没有可匹配的「第05集」'), findsOneWidget);
    expect(focus(), 'detail-source-switch');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    await key(tester, LogicalKeyboardKey.select);
    expect(played!['videoId'], 'a-video');
    expect(played!['initialEpisodeIndex'], 1);
    expect(played!['initialPositionMs'], 77777);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TV: 默认首页片源使用正确身份与线路，手动切源和返回恢复焦点', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final video = vb.withSources('a:a-video', [va, vb]);
    final view = _View(
      video,
      AggregateDetailState(
        candidates: [va, vb],
        resolved: [resolved(a, va, emptyFirst: true), resolved(b, vb)],
        completed: 2,
        initialSelection: 'a:a-video',
      ),
    );
    Map<String, dynamic>? played;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => AggregateDetailScreen(video: video),
        ),
        GoRoute(
          path: '/player',
          builder: (_, state) {
            played = state.extra as Map<String, dynamic>;
            return const Scaffold(body: Text('播放页'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aggregateDetailProvider.overrideWith((ref, _) => view),
          sitesProvider.overrideWith((ref) => [a, b]),
          favoriteStorageProvider.overrideWithValue(_Favorites()),
          historyStorageProvider.overrideWithValue(_History()),
          coverResolverProvider.overrideWithValue(_NoCover()),
        ],
        child: MaterialApp.router(routerConfig: router, theme: AppTheme.dark),
      ),
    );
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(focus(), 'detail-play');
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('当前片源：片源甲'), findsOneWidget);
    expect(find.text('推荐播放'), findsNothing);
    await key(tester, LogicalKeyboardKey.select);
    expect((played!['site'] as Site).key, 'a');
    expect(played!['videoId'], 'a-video');
    expect(played!['initialGroupIndex'], 1);
    router.pop();
    await settle(tester);
    expect(focus(), 'detail-play');
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focus(), 'detail-source-switch');
    await key(tester, LogicalKeyboardKey.select);
    expect(focus(), 'detail-source-a:a-video');
    await key(tester, LogicalKeyboardKey.gameButtonB);
    expect(focus(), 'detail-source-switch');
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focus(), 'detail-source-b:b-video');
    await key(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(seconds: 2));
    expect(focus(), 'detail-source-switch');
    expect(find.text('当前片源：片源乙'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(focus(), 'detail-play');
    await key(tester, LogicalKeyboardKey.select);
    expect((played!['site'] as Site).key, 'b');
    expect(played!['videoId'], 'b-video');
    expect(played!['initialGroupIndex'], 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [
    const Size(320, 640),
    const Size(800, 390),
    const Size(960, 540),
  ]) {
    testWidgets('聚合详情与切源适配 $size 和大字号', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final video = va.withSources('a:a-video', [va, vb]);
      final view = _View(
        video,
        AggregateDetailState(
          candidates: [va, vb],
          resolved: [resolved(a, va), resolved(b, vb)],
          completed: 2,
          initialSelection: 'b:b-video',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aggregateDetailProvider.overrideWith((ref, _) => view),
            sitesProvider.overrideWith((ref) => [a, b]),
            favoriteStorageProvider.overrideWithValue(_Favorites()),
            historyStorageProvider.overrideWithValue(_History()),
            coverResolverProvider.overrideWithValue(_NoCover()),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.3)),
              child: child!,
            ),
            home: AggregateDetailScreen(video: video),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.ensureVisible(find.text('切换片源（2）'));
      await tester.tap(find.text('切换片源（2）'));
      await settle(tester);
      expect(find.text('选择片源'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'detail-source-switch');
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('所有片源加载失败时仍能重试或通过遥控器返回', (tester) async {
    final video = va.withSources('a:a-video', [va, vb]);
    final view = _View(
      video,
      const AggregateDetailState(
        candidates: [va, vb],
        completed: 2,
        failures: {'a:a-video': '连接超时', 'b:b-video': '连接超时'},
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aggregateDetailProvider.overrideWith((ref, _) => view),
          sitesProvider.overrideWith((ref) => [a, b]),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: AggregateDetailScreen(video: video),
        ),
      ),
    );
    await settle(tester);
    expect(focus(), 'aggregate-back');
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focus(), 'aggregate-retry');
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('选择片源'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.gameButtonB);
    expect(focus(), 'aggregate-retry');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

String? focus() => FocusManager.instance.primaryFocus?.debugLabel;
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await settle(tester);
}

class _View extends AggregateDetailNotifier {
  _View(VideoItem video, AggregateDetailState initial)
    : super(
        api: CmsApi(Dio()),
        sites: {'a': a, 'b': b},
        scoreSource: (_) => 0,
        candidates: video.sources,
      ) {
    state = initial;
  }
}

class _Favorites extends FavoriteStorage {
  @override
  bool isFavorited(String videoId, String siteKey) => false;
}

class _History extends HistoryStorage {
  final List<WatchHistory> items;
  _History([this.items = const []]);
  @override
  List<WatchHistory> getAllUnfiltered() => List.of(items);
}

WatchHistory watch(
  VideoItem video,
  String name,
  int position, {
  int episode = 0,
}) => WatchHistory(
  videoId: video.id,
  siteKey: video.siteKey,
  title: video.title,
  cover: '',
  episodeName: name,
  episodeIndex: episode,
  positionMs: position,
  durationMs: 1000000,
  updatedAt: DateTime.utc(2026, 10, 13),
);

Future<GoRouter> pumpDetail(
  WidgetTester tester,
  AggregateDetailState state, {
  required HistoryStorage history,
  required void Function(Map<String, dynamic>) onPlay,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final video = va.withSources('a:a-video', [va, vb]);
  final view = _View(video, state);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => AggregateDetailScreen(video: video),
      ),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          onPlay(state.extra as Map<String, dynamic>);
          return const Scaffold(body: Text('播放页'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aggregateDetailProvider.overrideWith((ref, _) => view),
        sitesProvider.overrideWith((ref) => [a, b]),
        favoriteStorageProvider.overrideWithValue(_Favorites()),
        historyStorageProvider.overrideWithValue(history),
        coverResolverProvider.overrideWithValue(_NoCover()),
      ],
      child: MaterialApp.router(routerConfig: router, theme: AppTheme.dark),
    ),
  );
  await settle(tester);
  await tester.pump(const Duration(seconds: 2));
  return router;
}

class _NoCover extends CoverResolver {
  @override
  Future<ResolvedCover?> resolve(String title, String? year) async => null;
}
