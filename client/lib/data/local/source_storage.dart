import 'dart:convert';
import 'package:hive/hive.dart';
import '../../core/config/official_sources.dart';
import '../models/official_source_catalog.dart';
import '../models/site.dart';
import '../models/source_config.dart';

/// 配置源 URL 持久化存储
class SourceStorage {
  static const _boxName = 'source_urls';

  /// 仅用于升级时识别并迁移两个旧内置 CMS 记录，不再作为离线兜底。
  static const builtInUrls = [
    'https://bfzyapi.com/api.php/provide/vod/',
    'https://www.hongniuzy2.com/api.php/provide/vod/',
  ];

  static const officialUrl = OfficialSources.url;
  static const defaultSelectedUrl = officialUrl;
  static const _officialMigrationKey = '_official_sources_migrated_v1';
  static const _officialEndpointMigrationKey =
      '_official_sources_http_ip_migrated_v1';
  static const _legacyOfficialUrl =
      'https://stvbox.cloud/streambox/sources.json';
  static const _officialSnapshotKey = '_official_sources_snapshot_v1';
  static const _liteMergeKey = '_official_lite_merged_v1';

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
    if (url == officialUrl) return '官方片源';
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

  /// 判断是否为应用管理的官方订阅分组（不包含用户手动添加的相同 CMS）。
  static bool isBuiltIn(String url) => url == officialUrl;

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

  OfficialSourceSnapshot? getOfficialSnapshot() {
    try {
      final raw = _box.get(_officialSnapshotKey);
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return OfficialSourceSnapshot(
        OfficialSourceCatalog.fromJson(json['catalog']),
        DateTime.parse(json['syncedAt'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  /// Document and metadata commit together, only after validation succeeded.
  Future<void> saveOfficialSnapshot(OfficialSourceSnapshot snapshot) =>
      _box.put(
        _officialSnapshotKey,
        jsonEncode({
          'catalog': snapshot.catalog.toJson(),
          'syncedAt': snapshot.syncedAt.toUtc().toIso8601String(),
        }),
      );

  /// Retire only the legacy Lite subscription already covered by the official
  /// cache. Keep its URL/cache for recovery and never change API-keyed preferences.
  Future<void> _mergeDuplicatedLite() async {
    if (_box.get(_liteMergeKey) == '1') return;
    final candidates = getAll()
        .where((url) => nameOf(url) == 'OuonnkiTV Lite')
        .toList();
    final official = getOfficialSnapshot()?.catalog.config.sites ?? <Site>[];
    if (candidates.isNotEmpty && official.isEmpty) return;
    final covered = {for (final site in official) (site.identity, site.type)};
    for (final url in candidates) {
      final cached = getCachedConfig(url);
      if (cached == null ||
          cached.sites.isEmpty ||
          getSelectedWarehouse(url) != null ||
          !cached.sites.every(
            (site) => covered.contains((site.identity, site.type)),
          )) {
        continue;
      }
      // Archive before retiring the subscription. Re-adding this URL restores
      // the retained cache; the completed migration will not remove it again.
      await _box.put('_merged_lite:$url', url);
      if (getSelected() == url) await setSelected(officialUrl);
      final keys = _box.keys
          .whereType<int>()
          .where((key) => _box.get(key) == url)
          .toList();
      await _box.deleteAll(keys);
    }
    await _box.put(_liteMergeKey, '1');
  }

  /// Only migrate identified legacy subscriptions. Never broadly clean up
  /// custom sources, preferences or warehouse selections.
  Future<void> initDefaultsIfEmpty() async {
    if (_box.get(_officialMigrationKey) != '1') {
      final selected = getSelected();
      if (builtInUrls.contains(selected) && getHomeSite() == null) {
        await setHomeSite(Site.canonicalApi(selected!));
      }
      final legacyKeys = _box.keys
          .whereType<int>()
          .where((key) => builtInUrls.contains(_box.get(key)))
          .toList();
      await _box.deleteAll(legacyKeys);
      if (builtInUrls.contains(selected)) await setSelected(officialUrl);
      await _box.put(_officialMigrationKey, '1');
    }
    await add(officialUrl);
    if (officialUrl != _legacyOfficialUrl &&
        _box.get(_officialEndpointMigrationKey) != '1') {
      // Only replace the former app-owned endpoint. The shared snapshot and
      // API-keyed preferences remain valid; other subscriptions are untouched.
      if (getSelected() == _legacyOfficialUrl) await setSelected(officialUrl);
      final legacyKeys = _box.keys
          .whereType<int>()
          .where((key) => _box.get(key) == _legacyOfficialUrl)
          .toList();
      await _box.deleteAll(legacyKeys);
      await _box.put(_officialEndpointMigrationKey, '1');
    }
    await _mergeDuplicatedLite();
    final selected = getSelected();
    if (selected == null || !getAll().contains(selected)) {
      await setSelected(defaultSelectedUrl);
    }
  }
}
