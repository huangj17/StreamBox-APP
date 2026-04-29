import 'cover_cache.dart';
import 'cover_resolver.dart';
import 'fetch_pool.dart';

/// 包装一个 [CoverResolver]，加缓存（正/反向）和并发限流。
///
/// 流程：
/// 1. 查缓存，命中直接返回（包括 negative cache 返回 null）
/// 2. 进入池排队；出队后再查一次缓存（可能在排队期间被其他任务写入）
/// 3. 调用 inner.resolve
/// 4. 结果写回缓存（命中 30d / miss 24h TTL）
class CachingPooledResolver implements CoverResolver {
  final CoverResolver inner;
  final CoverCache cache;
  final FetchPool pool;

  CachingPooledResolver({
    required this.inner,
    required this.cache,
    required this.pool,
  });

  @override
  Future<ResolvedCover?> resolve(String title, String? year) async {
    if (title.trim().isEmpty) return null;

    final cached = cache.get(title, year);
    if (cached != null) {
      return cached.url == null
          ? null
          : ResolvedCover(cached.url!, cached.source);
    }

    return pool.run<ResolvedCover?>(() async {
      final again = cache.get(title, year);
      if (again != null) {
        return again.url == null
            ? null
            : ResolvedCover(again.url!, again.source);
      }

      final result = await inner.resolve(title, year);
      if (result != null) {
        await cache.putHit(title, year, result.url, result.source);
      } else {
        await cache.putMiss(title, year);
      }
      return result;
    });
  }
}
