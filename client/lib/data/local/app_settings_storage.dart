import 'package:hive/hive.dart';

/// 应用级设置本地存储（Hive）
///
/// 与 PlayerSettingsStorage 分开：后者专注于播放器（硬解/倍速），
/// 这里放应用级配置（如 TMDB API key、未来的主题/语言切换等）。
class AppSettingsStorage {
  static const _boxName = 'app_settings';
  static const _keyTmdbApiKey = 'tmdb_api_key';

  late Box _box;

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  String get tmdbApiKey => (_box.get(_keyTmdbApiKey) as String?)?.trim() ?? '';
  set tmdbApiKey(String value) => _box.put(_keyTmdbApiKey, value.trim());
}
