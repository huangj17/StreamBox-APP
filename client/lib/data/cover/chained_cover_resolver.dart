import 'cover_resolver.dart';

/// 依次调用一组 [CoverResolver]，第一个返回非 null 就停。
///
/// 任何子 resolver 抛异常被当作 null 处理，保证链路健壮。
class ChainedCoverResolver implements CoverResolver {
  final List<CoverResolver> resolvers;

  ChainedCoverResolver(this.resolvers);

  @override
  Future<ResolvedCover?> resolve(String title, String? year) async {
    for (final r in resolvers) {
      try {
        final result = await r.resolve(title, year);
        if (result != null) return result;
      } catch (_) {
        // 继续下一个 resolver
      }
    }
    return null;
  }
}
