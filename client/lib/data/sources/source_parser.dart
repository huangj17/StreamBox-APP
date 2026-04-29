import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/source_config.dart';
import '../models/site.dart';
import '../models/warehouse.dart';

/// TVBox 配置源解析器
/// 下载 URL → 解析 JSON → 提取 sites 列表
/// 支持单仓（sites 数组）和多仓（urls / storeHouse 数组）格式
class SourceParser {
  final Dio _dio;

  SourceParser(this._dio);

  /// 从 URL 下载并解析 TVBox 单仓配置
  Future<SourceConfig> parse(String url) async {
    final json = await _fetchJson(url);
    return SourceConfig.fromJson(json);
  }

  /// 尝试将 URL 解析为多仓配置
  /// 返回仓库列表；如果不是多仓格式则返回 null
  Future<List<Warehouse>?> parseMultiWarehouse(String url) async {
    final json = await _fetchJson(url);
    return _tryParseWarehouses(json);
  }

  /// 下载 URL 并解码为 JSON Map
  Future<Map<String, dynamic>> _fetchJson(String url) async {
    final response = await _dio.get(
      url,
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    final jsonStr = response.data as String;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
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
          .map((e) => Warehouse(
                name: (e['name'] as String?) ?? '',
                url: e['url'] as String,
              ))
          .toList();
    }

    // 格式 2: storeHouse 数组
    final storeHouse = json['storeHouse'];
    if (storeHouse is List && storeHouse.isNotEmpty) {
      return storeHouse
          .whereType<Map<String, dynamic>>()
          .where((e) => e['sourceUrl'] != null)
          .map((e) => Warehouse(
                name: (e['sourceName'] as String?) ?? '',
                url: e['sourceUrl'] as String,
              ))
          .toList();
    }

    return null;
  }

  /// 判断 URL 是 TVBox 配置源还是直接的苹果 CMS API 地址
  /// TVBox 配置通常以 .json 结尾或包含 sites 字段
  /// 苹果 CMS API 通常包含 api.php/provide/vod
  static bool isCmsApiUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('api.php') || lower.contains('provide/vod');
  }

  /// 判断 URL 是否是 JAR Bridge 服务**根地址**（用于自动发现 /api/list）。
  /// 含 `/api/<key>` 的子路径不算 —— 那是单个插件的 CMS 端点，按普通 CMS 源处理，
  /// 这样用户可以手动添加 `http://<bridge>:9978/api/<key>` 形式访问 hidden 插件。
  static bool isJarBridgeUrl(String url) {
    final lower = url.toLowerCase();
    if (!lower.contains(':9978')) return false;
    // 提取 :9978 后的路径部分
    final idx = lower.indexOf(':9978');
    final afterPort = lower.substring(idx + ':9978'.length);
    // 路径只能为空、'/'、或非 /api/ 开头
    return !afterPort.contains('/api/');
  }

  /// 解析 JAR Bridge 服务，通过 /api/list 发现所有可用插件
  Future<SourceConfig> parseJarBridge(String bridgeUrl) async {
    final baseUrl = bridgeUrl.endsWith('/') ? bridgeUrl.substring(0, bridgeUrl.length - 1) : bridgeUrl;
    final response = await _dio.get(
      '$baseUrl/api/list',
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 10),
      ),
    );

    final data = jsonDecode(response.data as String) as Map<String, dynamic>;
    final sources = data['sources'] as List<dynamic>? ?? [];

    final sites = sources.map((s) {
      final map = s as Map<String, dynamic>;
      return Site.fromBridge(
        bridgeUrl: baseUrl,
        key: map['key'] as String,
        name: map['name'] as String,
        apiPath: map['api'] as String,
      );
    }).toList();

    return SourceConfig(sites: sites);
  }

  /// 将普通 CMS API URL 包装为 SourceConfig
  static SourceConfig wrapCmsUrl(String url) {
    return SourceConfig(
      sites: [Site.fromUrl(url)],
    );
  }
}
