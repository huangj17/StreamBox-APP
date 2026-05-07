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
final sitesProvider = StateProvider<List<Site>>((ref) => []);

// ── 数据 Provider ──

/// 分类列表（固定行 + 动态行合并，按用户观看历史排序）
final categoriesProvider = FutureProvider<List<Category>>((ref) async {
  final sites = ref.watch(sitesProvider);
  if (sites.isEmpty) return [];
  final repo = ref.read(homeRepositoryProvider);
  final historyStorage = ref.read(historyStorageProvider);
  final weights = historyStorage.getCategoryWeights();
  return repo.getCategories(sites, categoryWeights: weights);
});

/// Banner 数据：从前若干个动态分类各取首条，凑够 5 条，保证内容多样性。
///
/// 复用 [categoryItemsProvider] family —— 与首屏前几行 rail 共享同一份请求，
/// 不产生冗余网络流量；同时把这些分类的首页数据并发预热，rail 渲染时直接命中缓存。
/// 完全自包含，绝不抛异常。
final bannerItemsProvider = FutureProvider<List<VideoItem>>((ref) async {
  final categories = await ref.watch(categoriesProvider.future);
  final dynamicCats =
      categories.where((c) => c.type == CategoryType.dynamic).toList();
  if (dynamicCats.isEmpty) return [];

  // 取前 8 个候选分类并发拉，最终保留前 5 条非空首条
  final picks = dynamicCats.take(8).toList();
  final results = await Future.wait(
    picks.map(
      (cat) => ref
          .read(categoryItemsProvider(cat.id).future)
          .then<VideoItem?>((r) => r.items.isNotEmpty ? r.items.first : null)
          .catchError((_) => null),
    ),
  );

  return results.whereType<VideoItem>().take(5).toList();
});

/// 每个分类行的内容（family：会话级缓存，避免滚动时重复请求导致数据错乱）
final categoryItemsProvider = FutureProvider.family<VideoListResult, String>(
  (ref, categoryId) async {
    final categories = await ref.watch(categoriesProvider.future);
    final sites = ref.watch(sitesProvider);
    final category = categories.firstWhere((c) => c.id == categoryId);
    final site = sites.firstWhere((s) => s.key == category.siteKey);
    final repo = ref.read(homeRepositoryProvider);
    return repo.getCategoryItems(site: site, categoryId: categoryId);
  },
);

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final historyStorageProvider = Provider<HistoryStorage>(
  (ref) => throw UnimplementedError('historyStorageProvider must be overridden'),
);

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final favoriteStorageProvider = Provider<FavoriteStorage>(
  (ref) => throw UnimplementedError('favoriteStorageProvider must be overridden'),
);

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final playerSettingsStorageProvider = Provider<PlayerSettingsStorage>(
  (ref) => throw UnimplementedError('playerSettingsStorageProvider must be overridden'),
);

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final searchHistoryStorageProvider = Provider<SearchHistoryStorage>(
  (ref) => throw UnimplementedError('searchHistoryStorageProvider must be overridden'),
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
