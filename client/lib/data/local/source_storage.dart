import 'dart:convert';
import 'package:hive/hive.dart';
import '../models/site.dart';
import '../models/source_config.dart';

/// 配置源 URL 持久化存储
class SourceStorage {
  static const _boxName = 'source_urls';

  /// 保留的内置 CMS 片源。
  static const builtInUrls = [
    'https://bfzyapi.com/api.php/provide/vod/',
    'https://www.hongniuzy2.com/api.php/provide/vod/',
  ];

  static const defaultSelectedUrl = 'https://bfzyapi.com/api.php/provide/vod/';
  static const _sourceCleanupKey = '_source_cleanup_version';
  static const _sourceCleanupVersion = '1';

  /// 已知片源的友好名称和描述。
  static const sourceInfo = <String, ({String name, String desc})>{
    'https://bfzyapi.com/api.php/provide/vod/': (
      name: '暴风资源',
      desc: 'HD · 13万+ · 多CDN',
    ),
    'https://www.hongniuzy2.com/api.php/provide/vod/': (
      name: '红牛资源',
      desc: '双线路 · 10万+',
    ),
  };

  /// 根据 URL 获取友好名称，未知源从域名提取
  static String nameOf(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed?.path.toLowerCase().contains('/ouonnkitv/') == true) {
      final file = parsed!.pathSegments.last.replaceFirst(
        RegExp(r'\.json$'),
        '',
      );
      return 'OuonnkiTV ${file == 'lite' ? 'Lite' : file}';
    }
    final info = sourceInfo[url];
    if (info != null) return info.name;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.host.replaceAll('www.', '').split('.').first;
  }

  /// 根据 URL 获取描述信息
  static String? descOf(String url) => sourceInfo[url]?.desc;

  /// 判断是否为内置 CMS API 片源
  static bool isBuiltIn(String url) => builtInUrls.contains(url);

  late Box<String> _box;

  Future<void> init() async {
    _box = await Hive.openBox<String>(_boxName);
  }

  /// 获取所有已保存的配置源 URL
  /// 只返回 add() 写入的整数键条目，过滤掉 '_selected' 字符串键
  List<String> getAll() =>
      _box.keys.whereType<int>().map((k) => _box.get(k)!).toList();

  /// 添加配置源 URL
  Future<void> add(String url) async {
    if (getAll().contains(url)) return;
    await _box.add(url);
  }

  /// 删除配置源 URL
  Future<void> remove(String url) async {
    final keys = _box.keys
        .whereType<int>()
        .where((key) => _box.get(key) == url)
        .toList();
    await _box.deleteAll([
      ...keys,
      '_wh:$url',
      '_bp:$url',
      '_config:$url',
      if (getSelected() == url) '_selected',
    ]);
  }

  /// 获取当前选中的配置源 URL
  String? getSelected() => _box.get('_selected');

  /// 设置当前选中的配置源 URL
  Future<void> setSelected(String url) async {
    await _box.put('_selected', url);
  }

  /// 获取多仓源上次选中的仓库 URL
  String? getSelectedWarehouse(String sourceUrl) => _box.get('_wh:$sourceUrl');

  /// 保存多仓源选中的仓库 URL
  Future<void> setSelectedWarehouse(
    String sourceUrl,
    String warehouseUrl,
  ) async {
    await _box.put('_wh:$sourceUrl', warehouseUrl);
  }

  /// 获取 Bridge 源上次选中的插件 key（null 表示"全部"或未记录过）
  String? getSelectedBridgePlugin(String sourceUrl) =>
      _box.get('_bp:$sourceUrl');

  /// 保存 Bridge 源选中的插件 key；传 null 表示"全部"（清除记录）
  Future<void> setSelectedBridgePlugin(String sourceUrl, String? key) async {
    if (key == null) {
      await _box.delete('_bp:$sourceUrl');
    } else {
      await _box.put('_bp:$sourceUrl', key);
    }
  }

  SourceConfig? getCachedConfig(String url) {
    final raw = _box.get('_config:$url');
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final config = SourceConfig.fromJson(json);
      return SourceConfig(
        sites: (json['sites'] as List)
            .map((s) => Site.fromCache(Map<String, dynamic>.from(s as Map)))
            .toList(),
        spider: config.spider,
        lives: config.lives,
        parses: config.parses,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> cacheConfig(String url, SourceConfig config) => _box.put(
    '_config:$url',
    jsonEncode({
      'sites': config.sites.map((s) => s.toJson()).toList(),
      'spider': config.spider,
      'lives': config.lives
          .map(
            (s) => {'name': s.name, 'url': s.url, 'playerType': s.playerType},
          )
          .toList(),
      'parses': config.parses
          .map((s) => {'name': s.name, 'url': s.url})
          .toList(),
    }),
  );

  Future<void> clearCachedConfig(String url) => _box.delete('_config:$url');

  Map<String, bool> getSiteEnabled() {
    final raw = _box.get('_site_enabled');
    if (raw == null) return {};
    return Map<String, bool>.from(jsonDecode(raw) as Map);
  }

  Future<void> setSiteEnabled(Map<String, bool> values) =>
      _box.put('_site_enabled', jsonEncode(values));

  String? getHomeSite() => _box.get('_home_site');
  Future<void> setHomeSite(String identity) => _box.put('_home_site', identity);

  /// 首次升级清理旧片源，之后只补充保留的内置 CMS 源。
  Future<void> initDefaultsIfEmpty() async {
    await _clearLegacySources();
    for (final url in builtInUrls) {
      await add(url);
    }
    final selected = getSelected();
    if (selected == null || !getAll().contains(selected)) {
      await setSelected(defaultSelectedUrl);
    }
  }

  /// 清理旧第三方配置（含失败/超时记录）、下架的 CMS 与 JAR 源。
  /// 使用一次性迁移，避免以后用户手动添加的配置在重启时被误删。
  Future<void> _clearLegacySources() async {
    if (_box.get(_sourceCleanupKey) == _sourceCleanupVersion) return;

    final keysToDelete = _box.keys.where((key) {
      if (key is int) return !isBuiltIn(_box.get(key)!);
      if (key == '_selected') return !isBuiltIn(_box.get(key)!);
      return key is String &&
          (key.startsWith('_wh:') || key.startsWith('_bp:'));
    }).toList();
    await _box.deleteAll(keysToDelete);
    await _box.put(_sourceCleanupKey, _sourceCleanupVersion);
  }
}
