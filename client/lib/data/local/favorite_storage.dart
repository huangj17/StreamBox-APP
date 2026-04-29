import 'package:hive/hive.dart';
import '../models/favorite_item.dart';

/// 收藏本地存储（Hive）
class FavoriteStorage {
  static const _boxName = 'favorites';

  late Box<Map> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
  }

  /// 获取全部收藏（按收藏时间倒序）
  List<FavoriteItem> getAll() {
    final list = _box.values
        .map((e) => FavoriteItem.fromMap(Map<String, dynamic>.from(e)))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  /// 添加收藏
  Future<void> add(FavoriteItem item) async {
    await _box.put(item.storageKey, item.toMap());
  }

  /// 取消收藏
  Future<void> remove(String storageKey) async {
    await _box.delete(storageKey);
  }

  /// 是否已收藏
  bool isFavorited(String videoId, String siteKey) {
    return _box.containsKey('${videoId}_$siteKey');
  }

  /// 清空全部收藏
  Future<void> clearAll() async {
    await _box.clear();
  }
}
