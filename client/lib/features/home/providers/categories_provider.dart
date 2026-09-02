import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/dio_client.dart';
import '../../../data/models/site.dart';
import '../../../data/models/category.dart';
import '../../../data/models/video_item.dart';
import '../../../data/models/video_list_result.dart';
import '../../../data/models/watch_history.dart';
import '../../../data/sources/cms_api.dart';
import '../../../data/repositories/home_repository.dart';
import '../../../data/local/history_storage.dart';
import '../../../data/local/favorite_storage.dart';
import '../../../data/local/player_settings_storage.dart';
import '../../../data/local/search_history_storage.dart';
import '../../../data/models/favorite_item.dart';
import '../../../data/models/source_health.dart';
import '../../source/providers/source_library_provider.dart';
import '../../source/providers/source_provider.dart';

// ── 基础设施 Provider ──

/// 全局 Dio 实例
final dioProvider = Provider((_) => createDio());

/// CmsApi 实例
final cmsApiProvider = Provider((ref) => CmsApi(ref.watch(dioProvider)));

/// HomeRepository 实例
final homeRepositoryProvider = Provider(
  (ref) => HomeRepository(ref.watch(cmsApiProvider)),
);

// ── 配置源 Provider（临时实现，后续由 source 模块接管）──

/// 当前已启用的 Site 列表
final sitesProvider = Provider<List<Site>>((ref) {
  // 配置加载状态、首页选择变化不会使全部影片缓存失效。
  ref.watch(
    sourceLibraryProvider.select(
      (library) =>
          jsonEncode(library.activeSites.map((s) => s.toJson()).toList()),
    ),
  );
  return ref.read(sourceLibraryProvider).activeSites;
});

/// 导航保留所有启用站点，搜索暂时跳过已明确检测失败的站点。
final searchSitesProvider = Provider<List<Site>>((ref) {
  final health = ref.watch(sourceHealthProvider);
  return ref
      .watch(sitesProvider)
      .where(
        (s) =>
            s.searchable &&
            health[s.api]?.status != SourceHealthStatus.unavailable,
      )
      .toList();
});

/// 首页只请求一个站点；当前源异常时优先使用检测通过的备用源。
final _homeSelectionProvider =
    Provider<({String key, String api, String name})?>((ref) {
      final sites = ref.watch(sitesProvider);
      final health = ref.watch(sourceHealthProvider);
      final preferred = ref.watch(
        sourceLibraryProvider.select((s) => s.homeIdentity),
      );
      final eligible = sites
          .where((s) => health[s.api]?.status != SourceHealthStatus.unavailable)
          .toList();
      if (eligible.isEmpty) return null;
      final site =
          eligible.where((s) => s.identity == preferred).firstOrNull ??
          eligible
              .where(
                (s) => health[s.api]?.status == SourceHealthStatus.available,
              )
              .firstOrNull ??
          eligible.first;
      return (key: site.key, api: site.api, name: site.name);
    });

final homeSitesProvider = Provider<List<Site>>((ref) {
  final selection = ref.watch(_homeSelectionProvider);
  if (selection == null) return [];
  return [ref.read(sitesProvider).firstWhere((s) => s.key == selection.key)];
});

// ── 数据 Provider ──

/// 分类列表（固定行 + 动态行合并，按用户观看历史排序）
final categoriesProvider = FutureProvider<List<Category>>((ref) async {
  final sites = ref.watch(homeSitesProvider);
  if (sites.isEmpty) return [];
  final repo = ref.read(homeRepositoryProvider);
  final historyStorage = ref.read(historyStorageProvider);
  final weights = historyStorage.getCategoryWeights();
  return repo.getCategories(sites, categoryWeights: weights);
});

/// Banner 数据：从第一个动态分类里随机挑 5 条。
///
/// 复用 [categoryItemsProvider] family —— 与首行 rail 共享同一份请求，
/// 只等 1 个 rail，banner 跟首行几乎同时出现，避免等齐多个分类的尾延迟。
/// 完全自包含，绝不抛异常。
final bannerItemsProvider = FutureProvider<List<VideoItem>>((ref) async {
  final categories = await ref.watch(categoriesProvider.future);
  final dynamicCats = categories
      .where((c) => c.type == CategoryType.dynamic)
      .toList();
  if (dynamicCats.isEmpty) return [];

  try {
    final first = dynamicCats.first;
    final result = await ref.read(
      categoryItemsProvider((
        siteKey: first.siteKey,
        categoryId: first.id,
      )).future,
    );
    final items = List<VideoItem>.from(result.items);
    if (items.isEmpty) return [];
    items.shuffle();
    return items.take(5).toList();
  } catch (_) {
    return [];
  }
});

/// 全局 rail fetch 并发闸：Bridge 后端 spider 单线程串行（每 plugin 一个
/// `Executors.newSingleThreadExecutor`），首页同时 N 个 rail 起飞会让 spider
/// 队列爆掉，排尾的命中 client 8s receiveTimeout fail。限到 4 并发后排队，
/// 单 rail 看起来稍慢但成功率显著上升。
final _railSemaphore = _AsyncSemaphore(4);

/// 每个分类行的内容（family：会话级缓存，避免滚动时重复请求导致数据错乱）
typedef CategoryItemsKey = ({String siteKey, String categoryId});

final categoryItemsProvider = FutureProvider.autoDispose
    .family<VideoListResult, CategoryItemsKey>((ref, key) async {
      // 离屏后短期保留，兼顾回滚体验与有界内存；切源/长时间离屏会释放。
      final keepAlive = ref.keepAlive();
      final expiry = Timer(const Duration(minutes: 5), keepAlive.close);
      ref.onDispose(expiry.cancel);
      final sites = ref.watch(sitesProvider);
      final site = sites.firstWhere((s) => s.key == key.siteKey);
      final repo = ref.read(homeRepositoryProvider);
      return _railSemaphore.run(
        () => repo.getCategoryItems(site: site, categoryId: key.categoryId),
      );
    });

/// 简单异步信号量。任务排队，先到先获 permit，释放后唤醒下一个等待者。
class _AsyncSemaphore {
  _AsyncSemaphore(this._permits);

  int _permits;
  final _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_permits > 0) {
      _permits--;
    } else {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    try {
      return await task();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _permits++;
      }
    }
  }
}

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final historyStorageProvider = Provider<HistoryStorage>(
  (ref) =>
      throw UnimplementedError('historyStorageProvider must be overridden'),
);

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final favoriteStorageProvider = Provider<FavoriteStorage>(
  (ref) =>
      throw UnimplementedError('favoriteStorageProvider must be overridden'),
);

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final playerSettingsStorageProvider = Provider<PlayerSettingsStorage>(
  (ref) => throw UnimplementedError(
    'playerSettingsStorageProvider must be overridden',
  ),
);

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final searchHistoryStorageProvider = Provider<SearchHistoryStorage>(
  (ref) => throw UnimplementedError(
    'searchHistoryStorageProvider must be overridden',
  ),
);

/// 观看历史（本地 Hive）
final watchHistoryProvider = FutureProvider<List<WatchHistory>>((ref) async {
  final storage = ref.watch(historyStorageProvider);
  return storage.getAll();
});

/// 收藏列表（本地 Hive）
final favoritesProvider = Provider<List<FavoriteItem>>((ref) {
  final storage = ref.watch(favoriteStorageProvider);
  return storage.getAll();
});
