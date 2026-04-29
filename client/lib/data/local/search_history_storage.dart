import 'package:hive/hive.dart';

/// 搜索历史本地存储（Hive）
/// 最多保存 20 条关键词，最近搜索的排在前面
class SearchHistoryStorage {
  static const _boxName = 'search_history';
  static const _key = 'keywords';
  static const _maxCount = 20;

  late Box<List> _box;

  Future<void> init() async {
    _box = await Hive.openBox<List>(_boxName);
  }

  /// 获取搜索历史（最新在前）
  List<String> getAll() {
    final list = _box.get(_key);
    if (list == null) return [];
    return list.cast<String>();
  }

  /// 添加关键词（已存在则提到最前）
  Future<void> add(String keyword) async {
    final list = getAll();
    list.remove(keyword);
    list.insert(0, keyword);
    if (list.length > _maxCount) list.removeLast();
    await _box.put(_key, list);
  }

  /// 删除单条
  Future<void> remove(String keyword) async {
    final list = getAll();
    list.remove(keyword);
    await _box.put(_key, list);
  }

  /// 清空全部
  Future<void> clearAll() async {
    await _box.put(_key, <String>[]);
  }
}
