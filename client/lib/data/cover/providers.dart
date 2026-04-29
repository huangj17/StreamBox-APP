import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/home/providers/categories_provider.dart';
import '../local/app_settings_storage.dart';
import 'bing_image_cover_resolver.dart';
import 'caching_resolver.dart';
import 'chained_cover_resolver.dart';
import 'cover_cache.dart';
import 'cover_resolver.dart';
import 'douban_cover_resolver.dart';
import 'fetch_pool.dart';
import 'tmdb_cover_resolver.dart';

/// 应用级设置存储（TMDB API key 等），由 main.dart 注入实际实例
final appSettingsStorageProvider = Provider<AppSettingsStorage>(
  (ref) => throw UnimplementedError(
      'appSettingsStorageProvider must be overridden'),
);

/// 封面查询缓存，由 main.dart 注入实际实例
final coverCacheProvider = Provider<CoverCache>(
  (ref) =>
      throw UnimplementedError('coverCacheProvider must be overridden'),
);

/// 全局封面查询并发池（最多 3 个并发请求）
final coverFetchPoolProvider =
    Provider<FetchPool>((ref) => FetchPool(maxConcurrent: 3));

/// 缓存版本号。每次用户「清除封面缓存」时 +1，已挂载的
/// ResolvableCover 监听此值重置状态并重新触发解析。
final coverCacheVersionProvider = StateProvider<int>((ref) => 0);

/// 统一的封面查询入口：TMDB 为首选，Step 3 会加入豆瓣。
final coverResolverProvider = Provider<CoverResolver>((ref) {
  final dio = ref.watch(dioProvider);
  final settings = ref.watch(appSettingsStorageProvider);
  final cache = ref.watch(coverCacheProvider);
  final pool = ref.watch(coverFetchPoolProvider);

  final tmdb = TmdbCoverResolver(dio, () => settings.tmdbApiKey);
  final douban = DoubanCoverResolver(dio);
  final bing = BingImageCoverResolver(dio);
  // 国内用户优先：豆瓣直连稳、中文覆盖广 → TMDB（3s 超时快速失败，海外片精准）
  // → Bing 图片搜索（国内可用，冷门片兜底）
  return CachingPooledResolver(
    inner: ChainedCoverResolver([douban, tmdb, bing]),
    cache: cache,
    pool: pool,
  );
});
