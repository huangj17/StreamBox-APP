import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/cms_video_detail.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/source_health.dart';
import 'package:streambox/data/models/source_config.dart';
import 'package:streambox/data/models/video_item.dart';
import 'package:streambox/data/sources/cms_api.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/data/sources/source_health_checker.dart';
import 'package:streambox/features/detail/providers/aggregate_detail_provider.dart';
import 'package:streambox/features/source/providers/source_playback_provider.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';
import 'package:streambox/features/source/providers/source_provider.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';

final sites = List.generate(
  4,
  (i) => Site(
    key: '$i',
    name: '片源 $i',
    type: 3,
    api: 'https://source$i.example/api',
  ),
);
final candidates = List.generate(
  4,
  (i) => VideoItem(
    id: 'movie',
    title: '沙丘',
    cover: '',
    siteKey: '$i',
    year: '2021',
  ),
);

CmsVideoDetail detail({
  int episodes = 1,
  String title = '沙丘',
  String year = '2021',
  bool parse = false,
}) => CmsVideoDetail(
  vodId: 'movie',
  vodName: title,
  vodPic: '',
  vodContent: '',
  vodYear: year,
  vodPlayFrom: '高清',
  vodPlayParse: parse ? '1' : '0',
  vodPlayUrl: List.generate(
    episodes,
    (i) => '第${i + 1}集\$https://media.example/$i.m3u8',
  ).join('#'),
);

void main() {
  test('首页片源不在候选中时使用可用候选，推荐评分不改变初始选择', () async {
    final api = ControlledApi();
    final notifier = AggregateDetailNotifier(
      api: api,
      sites: {for (final s in sites) s.key: s},
      scoreSource: (_) => 0,
      candidates: candidates,
      preferredSiteIdentity: 'https://missing.example/api',
    );
    addTearDown(notifier.dispose);
    final loading = notifier.load();
    expect(api.pending.keys, ['0', '1', '2']);
    api.pending['0']!.complete(detail(episodes: 1));
    api.pending['1']!.complete(detail(episodes: 2));
    api.pending['2']!.complete(detail(episodes: 3));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.initialSelection, '0:movie');
    expect(notifier.state.loading, isTrue);
    api.pending['3']!.complete(detail(episodes: 30));
    await loading;
    expect(notifier.state.initialSelection, '0:movie');
    expect(notifier.state.ranked.first.identity, '3:movie');
    expect(notifier.state.loading, isFalse);
  });

  test('首页片源先单独加载并立即显示，其他源评分更高也不替换', () async {
    final api = ControlledApi();
    final notifier = AggregateDetailNotifier(
      api: api,
      sites: {for (final s in sites) s.key: s},
      scoreSource: (site) => site.key == '3' ? -100 : 100,
      candidates: candidates,
      preferredSiteIdentity: sites[3].identity,
    );
    addTearDown(notifier.dispose);
    final loading = notifier.load();
    expect(api.pending.keys, ['3']);
    api.pending['3']!.complete(detail());
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.initialSelection, '3:movie');
    expect(notifier.state.completed, 1);
    expect(notifier.state.loading, isTrue);
    for (final key in ['0', '1', '2']) {
      api.pending[key]!.complete(detail(episodes: 30));
    }
    await loading;
    expect(notifier.state.initialSelection, '3:movie');
    expect(notifier.state.ranked.first.identity, isNot('3:movie'));
  });

  test('首页片源加载失败后才回退到其他可用片源', () async {
    final api = ControlledApi();
    final notifier = AggregateDetailNotifier(
      api: api,
      sites: {for (final s in sites) s.key: s},
      scoreSource: (_) => 0,
      candidates: candidates,
      preferredSiteIdentity: sites[3].identity,
    );
    addTearDown(notifier.dispose);
    final loading = notifier.load();
    expect(api.pending.keys, ['3']);
    api.pending['3']!.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.initialSelection, isNull);
    for (final key in ['0', '1', '2']) {
      api.pending[key]!.complete(detail());
    }
    await loading;
    expect(notifier.state.initialSelection, '0:movie');
    expect(notifier.state.failures, contains('3:movie'));
  });

  test('聚合详情读取设置保存的首页身份，健康检测不会覆盖明确选择', () async {
    final api = ControlledApi();
    final container = ProviderContainer(
      overrides: [
        cmsApiProvider.overrideWithValue(api),
        sourceLibraryProvider.overrideWith(
          (ref) => _Library(sites[3].identity),
        ),
        sourceHealthProvider.overrideWith(
          (ref) => _Health({
            sites[0].api: SourceHealth.available(),
            sites[3].api: SourceHealth.unavailable(message: '抽查失败'),
          }),
        ),
      ],
    );
    addTearDown(container.dispose);
    final video = candidates.first.withSources('0:movie', candidates);
    final provider = aggregateDetailProvider(video);
    container.listen(provider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(homeSitesProvider).first.key, '0');
    expect(api.pending.keys, ['3']);
    api.pending['3']!.complete(detail());
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).initialSelection, '3:movie');
    for (final key in ['0', '1', '2']) {
      api.pending[key]!.complete(detail());
    }
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).loading, isFalse);
  });

  test('错误片名、错误年份和必须网页解析的线路不能推荐', () async {
    final api = ControlledApi();
    final notifier = AggregateDetailNotifier(
      api: api,
      sites: {for (final s in sites) s.key: s},
      scoreSource: (_) => 0,
      candidates: candidates,
    );
    addTearDown(notifier.dispose);
    final loading = notifier.load();
    api.pending['0']!.complete(detail(title: '另一部电影'));
    api.pending['1']!.complete(detail(year: '1984'));
    api.pending['2']!.complete(detail(parse: true));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.initialSelection, isNull);
    api.pending['3']!.complete(detail());
    await loading;
    expect(notifier.state.failures, hasLength(3));
    expect(notifier.state.initialSelection, '3:movie');
  });

  test('失败源可重试，退出取消详情请求且迟到结果不写状态', () async {
    final api = ControlledApi();
    final notifier = AggregateDetailNotifier(
      api: api,
      sites: {'0': sites.first},
      scoreSource: (_) => 0,
      candidates: [candidates.first],
    );
    final loading = notifier.load();
    api.pending['0']!.completeError(StateError('offline'));
    await loading;
    expect(notifier.state.failures, hasLength(1));
    final retry = notifier.retry(candidates.first);
    api.pending['0']!.complete(detail());
    await retry;
    expect(notifier.state.failures, isEmpty);
    expect(notifier.state.initialSelection, '0:movie');
    final second = notifier.retry(candidates.first);
    final token = api.tokens['0']!;
    notifier.dispose();
    expect(token.isCancelled, isTrue);
    api.pending['0']!.complete(detail());
    await second;
  });

  test('真实成功记录与检测影响推荐，记录数量有上限', () {
    final stats = SourcePlaybackNotifier();
    addTearDown(stats.dispose);
    final health = {sites.first.api: SourceHealth.available()};
    expect(
      sourceRecommendationScore(sites.first, health, {}),
      greaterThan(sourceRecommendationScore(sites[1], health, {})),
    );
    for (var i = 0; i < 12; i++) {
      stats.record(sites[1], succeeded: true, startupMs: 1000);
    }
    expect(stats.state[sites[1].identity], hasLength(8));
    expect(
      sourceRecommendationScore(sites[1], {}, stats.state),
      greaterThan(0),
    );
  });
}

class ControlledApi extends CmsApi {
  ControlledApi() : super(Dio());
  final pending = <String, Completer<CmsVideoDetail?>>{};
  final tokens = <String, CancelToken>{};
  @override
  Future<CmsVideoDetail?> fetchVideoDetail({
    required Site site,
    required String videoId,
    CancelToken? cancelToken,
  }) {
    tokens[site.key] = cancelToken!;
    return (pending[site.key] = Completer<CmsVideoDetail?>()).future;
  }
}

class _Library extends SourceLibraryNotifier {
  _Library(String home) : super(SourceStorage(), SourceParser(Dio())) {
    state = SourceLibrary(
      homeIdentity: home,
      groups: {
        'https://config.example/box.json': SourceGroup(
          url: 'https://config.example/box.json',
          config: SourceConfig(sites: sites),
        ),
      },
    );
  }
}

class _Health extends SourceHealthNotifier {
  _Health(Map<String, SourceHealth> health)
    : super(SourceHealthChecker(Dio())) {
    state = health;
  }
}
