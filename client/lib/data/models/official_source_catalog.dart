import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/config/official_sources.dart';
import '../../core/network/url_policy.dart';
import 'site.dart';
import 'source_config.dart';

/// A complete, validated snapshot. Accepts id/name/url arrays and legacy
/// versioned objects; explicit empty lists take all official sources offline.
class OfficialSourceCatalog {
  final String version;
  final SourceConfig config;
  final Object _document;

  // The uploaded list uses this ID for the formerly bundled Hongniu source.
  // Keep its local history key stable even when its API address changes.
  static const _arrayIdAliases = {'www-hongniuzy-com': 'hongniu'};

  const OfficialSourceCatalog._(this.version, this.config, this._document);

  factory OfficialSourceCatalog.fromJson(Object? json) {
    final isArray = json is List;
    final Object? entries;
    String? version;
    if (json is List) {
      entries = json;
    } else if (json is Map<String, dynamic>) {
      if (json['schemaVersion'] != 1) {
        throw const FormatException('不支持的片源配置格式版本');
      }
      final declaredVersion = json['version'];
      if (declaredVersion is! String ||
          declaredVersion.trim().isEmpty ||
          declaredVersion.length > 80) {
        throw const FormatException('配置需要有效的 version');
      }
      version = declaredVersion.trim();
      entries = json['sites'];
    } else {
      throw const FormatException('官方配置需要 JSON 数组或带 sites 的对象');
    }
    if (entries is! List || entries.length > 200) {
      throw const FormatException('配置需要片源数组，最多 200 个片源');
    }
    final keys = <String>{};
    final apis = <String>{};
    final sites = <Site>[];
    final normalized = <Map<String, dynamic>>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('片源条目必须是对象');
      }
      final key = entry[isArray ? 'id' : 'key'];
      final name = entry['name'];
      final api = entry[isArray ? 'url' : 'api'];
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
        throw FormatException(
          isArray
              ? '片源需要有效的 id、name、url 和 CMS type'
              : '片源需要有效的 key、name、api 和 CMS type',
        );
      }
      if (isArray) {
        // Store public HTTP metadata without authorizing requests to it.
        // Site.isSupported keeps such rows out of search, home and health checks.
        UrlPolicy.requireCatalogApiUrl(api);
      } else {
        UrlPolicy.requireCmsApiUrl(api);
      }
      if (Uri.parse(api.trim()).path.toLowerCase().endsWith('.js')) {
        throw const FormatException('官方配置不支持脚本或 JAR 插件');
      }
      for (final flag in ['searchable', 'isEnabled']) {
        if (entry.containsKey(flag) && entry[flag] is! bool) {
          throw FormatException('$flag 必须是 true 或 false');
        }
      }
      final detailUrl = entry['detailUrl'];
      if (isArray &&
          entry.containsKey('detailUrl') &&
          (detailUrl is! String || detailUrl.length > 2048)) {
        throw const FormatException('detailUrl 必须是有效字符串');
      }
      final stableKey = isArray ? (_arrayIdAliases[key] ?? key) : key;
      if (!keys.add(stableKey) || !apis.add(Site.canonicalApi(api))) {
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
      normalized.add(
        isArray
            ? {
                'id': key,
                'name': item['name'],
                'url': item['api'],
                if (detailUrl is String) 'detailUrl': detailUrl.trim(),
                'type': type,
                'searchable': item['searchable'],
                'isEnabled': item['isEnabled'],
              }
            : item,
      );
      // Preserve old built-in history/favorite keys, including after URL changes.
      final legacyApi = OfficialSources.legacyApis[stableKey];
      sites.add(
        Site.fromJson(item).copyWith(
          key: legacyApi == null
              ? 'official:$stableKey'
              : legacyApi.hashCode.toString(),
        ),
      );
    }
    // Display-only content revision: whitespace and object key order do not
    // change it. This is not a signature and never gates accepting an update.
    version ??=
        'array-${sha256.convert(utf8.encode(jsonEncode(normalized))).toString().substring(0, 12)}';
    return OfficialSourceCatalog._(
      version,
      SourceConfig(sites: List.unmodifiable(sites)),
      isArray
          ? normalized
          : {'schemaVersion': 1, 'version': version, 'sites': normalized},
    );
  }

  Object toJson() => _document;
}

class OfficialSourceSnapshot {
  final OfficialSourceCatalog catalog;
  final DateTime syncedAt;
  const OfficialSourceSnapshot(this.catalog, this.syncedAt);
}
