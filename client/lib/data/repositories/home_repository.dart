import '../sources/cms_api.dart';
import '../models/site.dart';
import '../models/category.dart';
import '../models/video_list_result.dart';

/// Home 模块数据组装层
class HomeRepository {
  final CmsApi _api;

  HomeRepository(this._api);

  /// 获取合并后的分类列表（固定行 + 动态行）
  /// [categoryWeights] 来自观看历史，key=分类名 value=观看次数
  Future<List<Category>> getCategories(
    List<Site> sites, {
    Map<String, int> categoryWeights = const {},
  }) async {
    // 固定行
    final fixed = <Category>[FixedCategories.watchHistory];

    // 并发请求所有 Site 的分类
    final results = await Future.wait(
      sites.map(
        (site) => _api.fetchCategories(site).catchError((_) => <Category>[]),
      ),
    );

    // 苹果 CMS 分类是两级结构：
    // typePid == 0 → 顶级父分类（电影/电视剧/动漫），无直接内容
    // typePid >  0 → 子分类（动作片/爱情片等），有实际内容
    // 必须逐站点判断：一个两级站点不能把另一个单层站点的全部分类过滤掉。
    // 不按名称跨站去重；同名分类属于不同数据源，身份是 siteKey + id。
    final dynamic = <Category>[];
    for (final categories in results) {
      final hasSubs = categories.any((c) => c.typePid > 0);
      dynamic.addAll(
        hasSubs ? categories.where((c) => c.typePid > 0) : categories,
      );
    }

    // 按用户观看历史排序：观看 ≥3 次的分类靠前，按次数降序
    if (categoryWeights.isNotEmpty) {
      dynamic.sort((a, b) {
        final wa = categoryWeights[a.name] ?? 0;
        final wb = categoryWeights[b.name] ?? 0;
        final ba = wa >= 3 ? 1 : 0;
        final bb = wb >= 3 ? 1 : 0;
        if (ba != bb) return bb.compareTo(ba); // 达标的排前面
        if (ba == 1 && bb == 1) return wb.compareTo(wa); // 都达标按次数排
        return 0; // 都不达标保持原顺序
      });
    }

    return [...fixed, ...dynamic];
  }

  /// 获取某分类的内容列表（首页只取第 1 页）
  Future<VideoListResult> getCategoryItems({
    required Site site,
    required String categoryId,
  }) => _api.fetchVideoList(site: site, categoryId: categoryId, page: 1);
}
