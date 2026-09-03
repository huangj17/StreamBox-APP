import '../../core/config/official_sources.dart';
import '../../core/network/url_policy.dart';
import 'site.dart';
import 'source_config.dart';

/// A complete, validated snapshot. Empty sites explicitly takes all official
/// sources offline; an absent/malformed sites field must never erase the cache.
class OfficialSourceCatalog {
  final String version;
  final SourceConfig config;
  final Map<String, dynamic> _document;

  const OfficialSourceCatalog._(this.version, this.config, this._document);

  factory OfficialSourceCatalog.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('不支持的片源配置格式版本');
    }
    final version = json['version'];
    final entries = json['sites'];
    if (version is! String || version.trim().isEmpty || version.length > 80) {
      throw const FormatException('配置需要有效的 version');
    }
    if (entries is! List || entries.length > 200) {
      throw const FormatException('配置需要 sites 数组，最多 200 个片源');
    }
    final keys = <String>{};
    final apis = <String>{};
    final sites = <Site>[];
    final normalized = <Map<String, dynamic>>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('片源条目必须是对象');
      }
      final key = entry['key'];
      final name = entry['name'];
      final api = entry['api'];
      final type = entry['type'] ?? 3;
      if (key is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(key) ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 100 ||
          api is! String ||
          api.length > 2048 ||
          type is! int ||
          !{0, 1, 3}.contains(type)) {
        throw const FormatException('片源需要有效的 key、name、api 和 CMS type');
      }
      UrlPolicy.requireCmsApiUrl(api);
      if (Uri.parse(api.trim()).path.toLowerCase().endsWith('.js')) {
        throw const FormatException('官方配置不支持脚本或 JAR 插件');
      }
      for (final flag in ['searchable', 'isEnabled']) {
        if (entry.containsKey(flag) && entry[flag] is! bool) {
          throw FormatException('$flag 必须是 true 或 false');
        }
      }
      if (!keys.add(key) || !apis.add(Site.canonicalApi(api))) {
        throw const FormatException('片源 key 或接口地址重复');
      }
      final item = <String, dynamic>{
        'key': key,
        'name': name.trim(),
        'api': api.trim(),
        'type': type,
        'searchable': entry['searchable'] ?? true,
        'isEnabled': entry['isEnabled'] ?? true,
      };
      normalized.add(item);
      // Preserve old built-in history/favorite keys, including after URL changes.
      final legacyApi = OfficialSources.bundledApis[key];
      sites.add(
        Site.fromJson(item).copyWith(
          key: legacyApi == null
              ? 'official:$key'
              : legacyApi.hashCode.toString(),
        ),
      );
    }
    return OfficialSourceCatalog._(
      version.trim(),
      SourceConfig(sites: List.unmodifiable(sites)),
      {'schemaVersion': 1, 'version': version.trim(), 'sites': normalized},
    );
  }

  Map<String, dynamic> toJson() => _document;

  static final bundled = OfficialSourceCatalog.fromJson({
    'schemaVersion': 1,
    'version': 'bundled-1',
    'sites': [
      for (final entry in OfficialSources.bundledApis.entries)
        {
          'key': entry.key,
          'name': entry.key == 'baofeng' ? '暴风资源' : '红牛资源',
          'type': 3,
          'api': entry.value,
        },
    ],
  });
}

class OfficialSourceSnapshot {
  final OfficialSourceCatalog catalog;
  final DateTime syncedAt;
  const OfficialSourceSnapshot(this.catalog, this.syncedAt);
}
