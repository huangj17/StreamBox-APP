import 'dart:convert';

import 'package:hive/hive.dart';

/// 单条缓存记录。url 为 null 表示曾查过但未命中（negative cache）。
class CachedCover {
  final String? url;
  final String source;
  final int fetchedAt;

  const CachedCover({
    required this.url,
    required this.source,
    required this.fetchedAt,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'source': source,
        'fetchedAt': fetchedAt,
      };

  factory CachedCover.fromJson(Map<String, dynamic> m) => CachedCover(
        url: m['url'] as String?,
        source: (m['source'] as String?) ?? 'unknown',
        fetchedAt: (m['fetchedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 第三方封面查询结果缓存：命中 30 天，miss 24 小时
class CoverCache {
  static const _boxName = 'cover_cache';
  static const _hitTtlMs = 30 * 24 * 60 * 60 * 1000;
  static const _missTtlMs = 24 * 60 * 60 * 1000;

  late Box _box;

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  String _keyFor(String title, String? year) =>
      '${title.trim().toLowerCase()}|${year?.trim() ?? ''}';

  /// 返回缓存项（可能 url=null 表示已知 miss），未缓存/已过期返回 null。
  CachedCover? get(String title, String? year) {
    final key = _keyFor(title, year);
    final raw = _box.get(key) as String?;
    if (raw == null) return null;
    try {
      final entry =
          CachedCover.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final age = DateTime.now().millisecondsSinceEpoch - entry.fetchedAt;
      final ttl = entry.url == null ? _missTtlMs : _hitTtlMs;
      if (age > ttl) {
        _box.delete(key);
        return null;
      }
      return entry;
    } catch (_) {
      _box.delete(key);
      return null;
    }
  }

  Future<void> putHit(
      String title, String? year, String url, String source) async {
    final entry = CachedCover(
      url: url,
      source: source,
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _box.put(_keyFor(title, year), jsonEncode(entry.toJson()));
  }

  Future<void> putMiss(String title, String? year) async {
    final entry = CachedCover(
      url: null,
      source: 'miss',
      fetchedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _box.put(_keyFor(title, year), jsonEncode(entry.toJson()));
  }

  /// 仅清除 miss 记录（保留成功命中的）——用户改 TMDB key 后调用，
  /// 让之前查不到的标题能重新走一遍
  Future<void> clearMisses() async {
    final toDelete = <dynamic>[];
    for (final key in _box.keys) {
      final raw = _box.get(key) as String?;
      if (raw == null) continue;
      try {
        final entry =
            CachedCover.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (entry.url == null) toDelete.add(key);
      } catch (_) {
        toDelete.add(key);
      }
    }
    await _box.deleteAll(toDelete);
  }

  /// 清空所有缓存
  Future<void> clearAll() async {
    await _box.clear();
  }
}
