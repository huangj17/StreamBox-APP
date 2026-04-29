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
      sites.map((site) => _api.fetchCategories(site).catchError((_) => <Category>[])),
    );

    // 合并所有分类
    final all = results.expand((list) => list).toList();

    // 苹果 CMS 分类是两级结构：
    // typePid == 0 → 顶级父分类（电影/电视剧/动漫），无直接内容
    // typePid >  0 → 子分类（动作片/爱情片等），有实际内容
    // 若存在子分类，只保留子分类；否则保留全部（兼容单层站点）
    final hasSubs = all.any((c) => c.typePid > 0);
    final filtered = hasSubs ? all.where((c) => c.typePid > 0).toList() : all;

    // 去重（按 name，保留第一个）
    final seen = <String>{};
    final dynamic = filtered.where((c) => seen.add(c.name)).toList();

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
