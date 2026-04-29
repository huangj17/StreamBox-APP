/// 第三方封面补全结果
class ResolvedCover {
  final String url;
  final String source; // 'tmdb' | 'douban'

  const ResolvedCover(this.url, this.source);

  /// 某些站点的图片有防盗链（如豆瓣），需要带 Referer 才能正常加载
  Map<String, String>? get httpHeaders {
    if (source == 'douban') {
      return const {'Referer': 'https://movie.douban.com/'};
    }
    return null;
  }
}

/// 封面查询器抽象接口。各实现负责单一来源（TMDB / 豆瓣等），
/// 组合/缓存/限流由上层包装器负责。
abstract class CoverResolver {
  Future<ResolvedCover?> resolve(String title, String? year);
}
