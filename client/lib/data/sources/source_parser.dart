import 'dart:convert';
import '../../core/config/official_sources.dart';
import 'package:dio/dio.dart';
import '../../core/network/bounded_response.dart';
import '../../core/network/gateway_auth.dart';
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
  static const _maxGatewayListBytes = 1024 * 1024;
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
    return SourceConfig.fromJson(json);
  }

  /// 下载一次配置文档，同时判断它是单仓还是多仓。
  Future<ParsedSourceDocument> parseDocument(
    String url, {
    RedirectUriValidator? redirectValidator,
  }) async {
    final json = await _fetchJson(url, redirectValidator: redirectValidator);
    final warehouses = _tryParseWarehouses(json);
    if (warehouses != null && warehouses.isNotEmpty) {
      return ParsedSourceDocument(warehouses: warehouses);
    }
    return ParsedSourceDocument(config: SourceConfig.fromJson(json));
  }

  /// 尝试将 URL 解析为多仓配置
  /// 返回仓库列表；如果不是多仓格式则返回 null
  Future<List<Warehouse>?> parseMultiWarehouse(
    String url, {
    RedirectUriValidator? redirectValidator,
  }) async {
    final json = await _fetchJson(url, redirectValidator: redirectValidator);
    return _tryParseWarehouses(json);
  }

  /// 统一 OuonnkiTV 数组/单对象与 TVBox 配置，仍由同一套 CMS 播放。
  Future<Map<String, dynamic>> _fetchJson(
    String url, {
    RedirectUriValidator? redirectValidator,
  }) async {
    final validated = UrlPolicy.requireConfigUrl(url);
    final jsonStr = await getBoundedText(
      _dio,
      validated.toString(),
      receiveTimeout: const Duration(seconds: 15),
      redirectValidator: redirectValidator,
      maxBytes: _maxConfigBytes,
    );
    final decoded = jsonDecode(jsonStr);
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
  static List<Warehouse>? _tryParseWarehouses(Map<String, dynamic> json) {
    // 格式 1: urls 数组
    final urls = json['urls'];
    if (urls is List && urls.isNotEmpty) {
      return urls
          .whereType<Map<String, dynamic>>()
          .where((e) => e['url'] != null)
          .map(
            (e) => Warehouse(
              name: (e['name'] as String?) ?? '',
              url: e['url'] as String,
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
              url: e['sourceUrl'] as String,
            ),
          )
          .toList();
    }

    return null;
  }

  /// 判断 URL 是 TVBox 配置源还是直接的苹果 CMS API 地址
  /// TVBox 配置通常以 .json 结尾或包含 sites 字段
  /// 苹果 CMS API 通常包含 api.php/provide/vod
  static bool isCmsApiUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('api.php') ||
        lower.contains('/inc/apijson.php') ||
        lower.contains('provide/vod') ||
        isJarBridgePluginUrl(url);
  }

  /// Bridge 单插件 CMS 兼容端点，例如 http://127.0.0.1:9978/api/doll。
  static bool isJarBridgePluginUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.port != 9978) return false;
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    return segments.length >= 2 &&
        segments[segments.length - 2].toLowerCase() == 'api' &&
        segments.last.isNotEmpty;
  }

  /// 判断 URL 是否是 JAR Bridge 服务**根地址**（用于自动发现 /api/list）。
  /// 含 `/api/<key>` 的子路径不算 —— 那是单个插件的 CMS 端点，按普通 CMS 源处理，
  /// 这样用户可以手动添加 `http://<bridge>:9978/api/<key>` 形式访问 hidden 插件。
  static bool isJarBridgeUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null && uri.port == 9978 && !isJarBridgePluginUrl(url);
  }

  /// 无路径的 HTTPS 地址可能是反向代理后的 Gateway；有明确配置文件路径的
  /// URL 不做 /api/list 探测，避免普通配置源额外等待 2 秒。
  static bool shouldProbeGateway(String url) {
    if (isJarBridgeUrl(url)) return true;
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.path.isEmpty || uri.path == '/') &&
        !uri.hasQuery;
  }

  /// 解析 JAR Bridge 服务，通过 /api/list 发现所有可用插件
  Future<SourceConfig> parseJarBridge(
    String bridgeUrl, {
    RedirectUriValidator? redirectValidator,
  }) async {
    final config = await probeGateway(
      bridgeUrl,
      redirectValidator: redirectValidator,
    );
    if (config == null) {
      throw const FormatException('URL 未返回有效的 StreamBox Gateway Schema');
    }
    return config;
  }

  /// 短超时探测 StreamBox Gateway。仅 HTTP 200 不足以通过，必须具备
  /// `code=200` 与结构合法的 `sources` 数组。
  Future<SourceConfig?> probeGateway(
    String gatewayUrl, {
    RedirectUriValidator? redirectValidator,
  }) async {
    final baseUrl = gatewayUrl.endsWith('/')
        ? gatewayUrl.substring(0, gatewayUrl.length - 1)
        : gatewayUrl;
    final Uri baseUri;
    try {
      baseUri = UrlPolicy.requireGatewayUrl(baseUrl);
    } on FormatException {
      return null;
    }
    try {
      final body = await getBoundedText(
        _dio,
        '$baseUrl/api/list',
        headers: GatewayAuth.headers,
        sendTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
        redirectValidator: redirectValidator,
        maxBytes: _maxGatewayListBytes,
      );
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic> || decoded['code'] != 200) {
        return null;
      }
      final rawSources = decoded['sources'];
      if (rawSources is! List<dynamic>) return null;

      final sites = <Site>[];
      for (final raw in rawSources) {
        if (raw is! Map<String, dynamic>) return null;
        final key = raw['key'];
        final name = raw['name'];
        final api = raw['api'];
        if (key is! String ||
            key.isEmpty ||
            name is! String ||
            api is! String ||
            api.isEmpty) {
          return null;
        }
        final status = _gatewayStatus(raw['status']);
        if (status != GatewaySourceStatus.ready &&
            status != GatewaySourceStatus.degraded) {
          continue;
        }
        final kind = _gatewayKind(raw['kind']);
        final site = Site.fromGateway(
          gatewayUrl: baseUrl,
          key: key,
          name: name,
          apiPath: api,
          kind: kind,
          status: status,
          searchable: _boolLike(raw['searchable'], defaultValue: true),
        );
        final resolved = Uri.tryParse(site.api);
        if (resolved == null ||
            resolved.scheme != baseUri.scheme ||
            resolved.host != baseUri.host ||
            resolved.port != baseUri.port) {
          return null;
        }
        sites.add(site);
      }
      return SourceConfig(sites: sites);
    } catch (_) {
      return null;
    }
  }

  static SiteSourceKind _gatewayKind(Object? value) =>
      switch (value?.toString().toLowerCase()) {
        'cms' => SiteSourceKind.cms,
        'manual' => SiteSourceKind.manual,
        'jar' || null || '' => SiteSourceKind.jar,
        _ => SiteSourceKind.unknown,
      };

  static GatewaySourceStatus _gatewayStatus(Object? value) =>
      switch (value?.toString().toLowerCase()) {
        'degraded' => GatewaySourceStatus.degraded,
        'failed' => GatewaySourceStatus.failed,
        'ready' || null || '' => GatewaySourceStatus.ready,
        _ => GatewaySourceStatus.unknown,
      };

  static bool _boolLike(Object? value, {required bool defaultValue}) =>
      switch (value) {
        final bool flag => flag,
        final num number => number != 0,
        final String text when text == '1' || text.toLowerCase() == 'true' =>
          true,
        final String text when text == '0' || text.toLowerCase() == 'false' =>
          false,
        _ => defaultValue,
      };

  /// 将普通 CMS API URL 包装为 SourceConfig
  static SourceConfig wrapCmsUrl(String url) {
    final directBridge = isJarBridgePluginUrl(url);
    final validated = UrlPolicy.requireCmsApiUrl(
      url,
      allowLoopback: directBridge,
    );
    if (directBridge) {
      final segments = validated.pathSegments
          .where((part) => part.isNotEmpty)
          .toList();
      final pluginKey = segments.last;
      final apiIndex = segments.length - 2;
      final basePath = segments.take(apiIndex).join('/');
      final gatewayUri = validated.replace(
        path: basePath.isEmpty ? '' : '/$basePath',
        query: null,
      );
      return SourceConfig(
        sites: [
          Site.fromGateway(
            gatewayUrl: gatewayUri.toString().replaceFirst(RegExp(r'/$'), ''),
            key: pluginKey,
            name: pluginKey,
            apiPath: validated.toString(),
            kind: SiteSourceKind.manual,
            status: GatewaySourceStatus.ready,
          ),
        ],
      );
    }
    return SourceConfig(sites: [Site.fromUrl(validated.toString())]);
  }
}
