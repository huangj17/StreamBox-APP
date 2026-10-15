import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/config/official_sources.dart';
import '../../core/network/url_policy.dart';
import 'site.dart';
import 'source_config.dart';

class OfficialSourceGroup {
  final String title;
  final String url;
  final SourceConfig? config;

  const OfficialSourceGroup({
    required this.title,
    required this.url,
    this.config,
  });

  bool get isInline => config != null;
}

/// A validated catalog of independent inline or remote configurations.
/// Legacy CMS arrays and versioned objects remain readable from disk/server.
class OfficialSourceCatalog {
  final String version;
  final SourceConfig config;
  final List<OfficialSourceGroup> groups;
  final Object _document;

  // The uploaded list uses this ID for the formerly bundled Hongniu source.
  // Keep its local history key stable even when its API address changes.
  static const _arrayIdAliases = {'www-hongniuzy-com': 'hongniu'};

  const OfficialSourceCatalog._(
    this.version,
    this.config,
    this.groups,
    this._document,
  );

  factory OfficialSourceCatalog.fromJson(Object? json) {
    if (json is List &&
        json.any(
          (e) => e is Map && (e.containsKey('title') || e.containsKey('data')),
        )) {
      return OfficialSourceCatalog._fromGroups(json);
    }
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
    final keys = <String, String>{};
    final apis = <String, Map<String, dynamic>>{};
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
      if (UrlPolicy.isRetiredBridgeUrl(api)) continue;
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
      final identity = Site.canonicalApi(api);
      final item = <String, dynamic>{
        'key': key,
        'name': name.trim(),
        'api': api.trim(),
        'type': type,
        'searchable': entry['searchable'] ?? true,
        'isEnabled': entry['isEnabled'] ?? true,
      };
      final previousIdentity = keys[stableKey];
      if (previousIdentity != null && previousIdentity != identity) {
        throw const FormatException('同一片源 ID 对应了不同接口地址');
      }
      final previous = apis[identity];
      if (previous != null) {
        // CMS lists often repeat an endpoint under another display name/ID.
        // Keep the first entry and its stable history identity. Conflicting
        // capabilities or official enablement remain an invalid update.
        if (!isArray ||
            previous['type'] != item['type'] ||
            previous['searchable'] != item['searchable'] ||
            previous['isEnabled'] != item['isEnabled']) {
          throw const FormatException('重复片源的类型或启用设置冲突');
        }
        keys[stableKey] = identity;
        continue;
      }
      keys[stableKey] = identity;
      apis[identity] = item;
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
      final historyKey = legacyApi != null
          ? legacyApi.hashCode.toString()
          : 'official:$stableKey';
      sites.add(Site.fromJson(item).copyWith(key: historyKey));
    }
    // Display-only content revision: whitespace and object key order do not
    // change it. This is not a signature and never gates accepting an update.
    version ??=
        'array-${sha256.convert(utf8.encode(jsonEncode(normalized))).toString().substring(0, 12)}';
    final config = SourceConfig(sites: List.unmodifiable(sites));
    return OfficialSourceCatalog._(
      version,
      config,
      [
        OfficialSourceGroup(
          title: '官方片源',
          url: OfficialSources.url,
          config: config,
        ),
      ],
      isArray
          ? normalized
          : {'schemaVersion': 1, 'version': version, 'sites': normalized},
    );
  }

  factory OfficialSourceCatalog._fromGroups(List<dynamic> entries) {
    if (entries.length > 200) {
      throw const FormatException('最多支持 200 个配置源');
    }
    final titles = <String>{};
    final urls = <String>{};
    final groups = <OfficialSourceGroup>[];
    final normalized = <Map<String, dynamic>>[];
    final sites = <Site>[];
    var siteCount = 0;
    for (final entry in entries) {
      if (entry is! Map<String, dynamic> ||
          entry['title'] is! String ||
          (entry['title'] as String).trim().isEmpty ||
          (entry['title'] as String).length > 100) {
        throw const FormatException('每个配置源都需要有效的 title');
      }
      final title = (entry['title'] as String).trim();
      if (!titles.add(title)) throw const FormatException('配置源名称不能重复');
      final data = entry['data'];
      if (data is List) {
        siteCount += data.length;
        if (siteCount > 200 ||
            data.any(
              (e) =>
                  e is! Map || e.containsKey('data') || e.containsKey('title'),
            )) {
          throw const FormatException('data 数组只支持 CMS 片源，总数最多 200 个');
        }
        final catalog = OfficialSourceCatalog.fromJson(data);
        // Every group has its own identity, including the first group. Legacy
        // single-catalog preferences are migrated explicitly by the library.
        final url =
            '${OfficialSources.url}#inline-${sha256.convert(utf8.encode(title))}';
        groups.add(
          OfficialSourceGroup(title: title, url: url, config: catalog.config),
        );
        sites.addAll(catalog.config.sites);
        normalized.add({'title': title, 'data': catalog.toJson()});
      } else if (data is String && data.trim().length <= 2048) {
        final url = UrlPolicy.requireConfigUrl(data.trim()).toString();
        UrlPolicy.requireCatalogApiUrl(url);
        if (UrlPolicy.isRetiredBridgeUrl(url) ||
            url == OfficialSources.url ||
            !urls.add(url)) {
          throw const FormatException('配置源地址重复或无效');
        }
        groups.add(OfficialSourceGroup(title: title, url: url));
        normalized.add({'title': title, 'data': url});
      } else {
        throw const FormatException('data 必须是 CMS 片源数组或配置源 URL');
      }
    }
    final version =
        'groups-${sha256.convert(utf8.encode(jsonEncode(normalized))).toString().substring(0, 12)}';
    return OfficialSourceCatalog._(
      version,
      SourceConfig(sites: List.unmodifiable(sites)),
      List.unmodifiable(groups),
      normalized,
    );
  }

  Object toJson() => _document;
}

class OfficialSourceSnapshot {
  final OfficialSourceCatalog catalog;
  final DateTime syncedAt;
  const OfficialSourceSnapshot(this.catalog, this.syncedAt);
}
