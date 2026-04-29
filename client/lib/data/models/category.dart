/// 分类类型
enum CategoryType {
  fixed,   // 固定行：继续观看等，数据来自本地
  dynamic, // 动态行：来自苹果 CMS ?ac=class 接口
}

/// 内容分类，用于首页 Rail 行标题
class Category {
  final String id;
  final String name;
  final String siteKey;
  final CategoryType type;
  /// 父分类 ID；0 表示顶级父分类（自身无内容），>0 表示子分类（有内容）
  final int typePid;

  const Category({
    required this.id,
    required this.name,
    this.siteKey = '',
    required this.type,
    this.typePid = 0,
  });

  factory Category.fromJson(Map<String, dynamic> json, {required String siteKey}) =>
      Category(
        id: json['type_id'].toString(),
        name: json['type_name'] as String,
        siteKey: siteKey,
        type: CategoryType.dynamic,
        typePid: (json['type_pid'] as num?)?.toInt() ?? 0,
      );
}

/// 预定义的固定行
class FixedCategories {
  static const watchHistory = Category(
    id: 'fixed_history',
    name: '继续观看',
    type: CategoryType.fixed,
  );
}
