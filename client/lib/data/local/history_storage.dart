import 'package:hive/hive.dart';
import '../models/watch_history.dart';

/// 观看历史本地存储（Hive）
/// 上限 20 条，进度 > 95% 视为看完
class HistoryStorage {
  static const _boxName = 'watch_history';
  static const _maxCount = 20;

  late Box<Map> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Map>(_boxName);
  }

  /// 获取继续观看列表（按最近观看时间排序，过滤已看完）
  Future<List<WatchHistory>> getAll({int limit = 20}) async {
    final list = _box.values
        .map((e) => WatchHistory.fromMap(Map<String, dynamic>.from(e)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return list
        .where((h) => h.progress < 0.95) // 过滤已看完
        .take(limit)
        .toList();
  }

  /// 获取全部历史记录（包含已看完，不限条数）
  List<WatchHistory> getAllUnfiltered() {
    final list = _box.values
        .map((e) => WatchHistory.fromMap(Map<String, dynamic>.from(e)))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// 清空全部历史
  Future<void> clearAll() async {
    await _box.clear();
  }

  /// 保存观看记录
  Future<void> save(WatchHistory h) async {
    await _box.put(h.storageKey, h.toMap());
    await _trimIfNeeded();
  }

  /// 删除指定记录
  Future<void> delete(String storageKey) async {
    await _box.delete(storageKey);
  }

  /// 统计各分类的观看次数（用于首页分类排序）
  Map<String, int> getCategoryWeights() {
    final weights = <String, int>{};
    for (final raw in _box.values) {
      final map = Map<String, dynamic>.from(raw);
      final cat = map['category'] as String?;
      if (cat != null && cat.isNotEmpty) {
        weights[cat] = (weights[cat] ?? 0) + 1;
      }
    }
    return weights;
  }

  /// 超出上限时删除最旧的
  Future<void> _trimIfNeeded() async {
    if (_box.length <= _maxCount) return;

    final entries = _box.keys.map((k) {
      final map = Map<String, dynamic>.from(_box.get(k)!);
      return MapEntry(k, WatchHistory.fromMap(map));
    }).toList()
      ..sort((a, b) => a.value.updatedAt.compareTo(b.value.updatedAt));

    final toDelete = entries
        .take(_box.length - _maxCount)
        .map((e) => e.key);
    await _box.deleteAll(toDelete);
  }
}
