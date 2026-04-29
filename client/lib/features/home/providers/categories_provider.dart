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

/// Banner 数据：从不同分类各取一条，凑够 5 条，保证内容多样性。
/// 完全自包含，绝不抛异常。
final bannerItemsProvider = FutureProvider<List<VideoItem>>((ref) async {
  final sites = ref.watch(sitesProvider);
  if (sites.isEmpty) return [];

  final api = ref.read(cmsApiProvider);
  final bannerItems = <VideoItem>[];

  for (final site in sites) {
    if (bannerItems.length >= 5) break;
    try {
      final categories = await api.fetchCategories(site);
      if (categories.isEmpty) continue;

      final hasSubs = categories.any((c) => c.typePid > 0);
      final candidates = hasSubs
          ? categories.where((c) => c.typePid > 0).toList()
          : categories;

      // 从每个分类取第一条，凑够 5 条
      for (final cat in candidates) {
        if (bannerItems.length >= 5) break;
        try {
          final result = await api.fetchVideoList(
            site: site,
            categoryId: cat.id,
            page: 1,
          );
          if (result.items.isNotEmpty) {
            bannerItems.add(result.items.first);
          }
        } catch (_) {
          continue;
        }
      }
    } catch (_) {
      continue;
    }
  }

  return bannerItems;
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
