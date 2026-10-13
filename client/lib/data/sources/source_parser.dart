import 'dart:convert';
import '../../core/config/official_sources.dart';
import 'package:dio/dio.dart';
import '../../core/network/bounded_response.dart';
import '../../core/network/url_policy.dart';
import '../models/source_config.dart';
import '../models/site.dart';
import '../models/warehouse.dart';
import '../models/official_source_catalog.dart';

class ParsedSourceDocument {
  final SourceConfig? config;
  final List<Warehouse> warehouses;

  const ParsedSourceDocument({this.config, this.warehouses = const []});
}

/// TVBox 配置源解析器
/// 下载 URL → 解析 JSON → 提取 sites 列表
/// 支持单仓（sites 数组）和多仓（urls / storeHouse 数组）格式
class SourceParser {
  static const _maxConfigBytes = 5 * 1024 * 1024;
  final Dio _dio;

  SourceParser(this._dio);

  Future<OfficialSourceCatalog> parseOfficialCatalog() async {
    final uri = UrlPolicy.requireOfficialConfigUrl(OfficialSources.url);
    final cancel = CancelToken();
    var secure = uri.scheme == 'https';
    try {
      final text = await getBoundedText(
        _dio,
        uri.toString(),
        headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
        receiveTimeout: const Duration(seconds: 10),
        cancelToken: cancel,
        redirectValidator: (next) {
          if (secure && next.scheme != 'https') {
            throw const FormatException('官方配置不允许从 HTTPS 降级到 HTTP');
          }
          UrlPolicy.requireOfficialConfigUrl(next.toString());
          secure = next.scheme == 'https';
        },
        maxBytes: 256 * 1024,
      ).timeout(const Duration(seconds: 20));
      return OfficialSourceCatalog.fromJson(jsonDecode(text));
    } finally {
      cancel.cancel('Official configuration request completed');
    }
  }

  /// 从 URL 下载并解析 TVBox 单仓配置
  Future<SourceConfig> parse(
    String url, {
    RedirectUriValidator? redirectValidator,
  }) async {
    final json = await _fetchJson(url, redirectValidator: redirectValidator);
    return SourceConfig.fromJson(json, configUrl: url);
  }

  /// 下载一次配置文档，同时判断它是单仓还是多仓。
  Future<ParsedSourceDocument> parseDocument(
    String url, {
    RedirectUriValidator? redirectValidator,
    CancelToken? cancelToken,
  }) async {
    final json = await _fetchJson(
      url,
      redirectValidator: redirectValidator,
      cancelToken: cancelToken,
    );
    final warehouses = _tryParseWarehouses(json, url);
    if (warehouses != null && warehouses.isNotEmpty) {
      return ParsedSourceDocument(warehouses: warehouses);
    }
    return ParsedSourceDocument(
      config: SourceConfig.fromJson(json, configUrl: url),
    );
  }

  /// 尝试将 URL 解析为多仓配置
  /// 返回仓库列表；如果不是多仓格式则返回 null
  Future<List<Warehouse>?> parseMultiWarehouse(
    String url, {
    RedirectUriValidator? redirectValidator,
  }) async {
    final json = await _fetchJson(url, redirectValidator: redirectValidator);
    return _tryParseWarehouses(json, url);
  }

  /// 统一 OuonnkiTV 数组/单对象与 TVBox 配置，仍由同一套 CMS 播放。
  Future<Map<String, dynamic>> _fetchJson(
    String url, {
    RedirectUriValidator? redirectValidator,
    CancelToken? cancelToken,
  }) async {
    final validated = UrlPolicy.requireConfigUrl(url);
    final jsonStr = await getBoundedText(
      _dio,
      validated.toString(),
      receiveTimeout: const Duration(seconds: 15),
      redirectValidator: redirectValidator,
      maxBytes: _maxConfigBytes,
      cancelToken: cancelToken,
    );
    final decoded = decodeSourceJson(jsonStr);
    if (decoded is List ||
        (decoded is Map<String, dynamic> &&
            decoded.containsKey('url') &&
            decoded.containsKey('name'))) {
      final entries = decoded is List ? decoded : [decoded];
      final sites = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final entry in entries) {
        if (entry is! Map ||
            entry['url'] is! String ||
            entry['name'] is! String) {
          throw const FormatException('片源列表中的每一项都需要名称和接口地址');
        }
        final api = (entry['url'] as String).trim();
        final name = (entry['name'] as String).trim();
        final uri = Uri.tryParse(api);
        if (name.isEmpty ||
            uri == null ||
            !uri.hasAuthority ||
            !['http', 'https'].contains(uri.scheme)) {
          throw const FormatException('片源名称或接口地址无效');
        }
        final identity = Site.canonicalApi(api);
        if (!seen.add(identity)) continue;
        sites.add({
          'key': 'cms:$identity',
          'name': name,
          'type': 3,
          'api': api,
          'isEnabled': entry['isEnabled'] ?? true,
        });
      }
      return {'sites': sites};
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('配置需要是 TVBox 对象或 CMS 片源列表');
    }
    return decoded;
  }

  /// 尝试从 JSON 中提取多仓仓库列表
  /// 格式 1: {"urls": [{"url": "...", "name": "..."}]}
  /// 格式 2: {"storeHouse": [{"sourceUrl": "...", "sourceName": "..."}]}
  static List<Warehouse>? _tryParseWarehouses(
    Map<String, dynamic> json,
    String base,
  ) {
    // 格式 1: urls 数组
    final urls = json['urls'];
    if (urls is List && urls.isNotEmpty) {
      return urls
          .whereType<Map<String, dynamic>>()
          .where((e) => e['url'] != null)
          .map(
            (e) => Warehouse(
              name: (e['name'] as String?) ?? '',
              url: Uri.parse(base).resolve(e['url'] as String).toString(),
            ),
          )
          .toList();
    }

    // 格式 2: storeHouse 数组
    final storeHouse = json['storeHouse'];
    if (storeHouse is List && storeHouse.isNotEmpty) {
      return storeHouse
          .whereType<Map<String, dynamic>>()
          .where((e) => e['sourceUrl'] != null)
          .map(
            (e) => Warehouse(
              name: (e['sourceName'] as String?) ?? '',
              url: Uri.parse(base).resolve(e['sourceUrl'] as String).toString(),
            ),
          )
          .toList();
    }

    return null;
  }

  static bool isCmsApiUrl(String url) {
    final lower = url.toLowerCase();
    return !UrlPolicy.isRetiredBridgeUrl(url) &&
        (lower.contains('api.php') ||
            lower.contains('/inc/apijson.php') ||
            lower.contains('provide/vod'));
  }

  static SourceConfig wrapCmsUrl(String url) {
    final api = UrlPolicy.requireCmsApiUrl(url).toString();
    return SourceConfig(sites: [Site.fromUrl(api)]);
  }
}

/// TVBox documents often contain JSON comments. Strip them with a string-aware
/// scanner so https:// URLs, regex strings and escaped quotes remain intact.
Object? decodeSourceJson(String source) {
  if (source.startsWith('\ufeff')) source = source.substring(1);
  final out = StringBuffer();
  var quoted = false;
  var escaped = false;
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (quoted) {
      out.write(c);
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
      continue;
    }
    if (c == '"') {
      quoted = true;
      out.write(c);
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      out.write('\n');
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final end = source.indexOf('*/', i + 2);
      if (end < 0) throw const FormatException('配置注释未结束');
      i = end + 1;
      continue;
    }
    out.write(c);
  }
  // Remove trailing commas in a second string-aware pass.
  final clean = out.toString();
  final result = StringBuffer();
  quoted = false;
  escaped = false;
  for (var i = 0; i < clean.length; i++) {
    final c = clean[i];
    if (!quoted && c == ',') {
      var j = i + 1;
      while (j < clean.length && clean[j].trim().isEmpty) {
        j++;
      }
      if (j < clean.length && (clean[j] == ']' || clean[j] == '}')) continue;
    }
    result.write(c);
    if (escaped) {
      escaped = false;
    } else if (quoted && c == r'\') {
      escaped = true;
    } else if (c == '"') {
      quoted = !quoted;
    }
  }
  return jsonDecode(result.toString());
}
