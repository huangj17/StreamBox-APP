/// 片源站点，来自 TVBox 配置 JSON 的 sites 数组
enum SiteSourceKind { cms, jar, manual, unknown }

enum GatewaySourceStatus { ready, degraded, failed, unknown }

class Site {
  final String key;
  final String name;
  final int type; // 0=XML, 1=JSON旧, 3=JSON主流, 4=TVBox JAR
  final String api;
  final bool searchable;
  final bool isEnabled;
  final SiteSourceKind sourceKind;
  final String? gatewayUrl;
  final GatewaySourceStatus gatewayStatus;

  const Site({
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    this.searchable = true,
    this.isEnabled = true,
    this.sourceKind = SiteSourceKind.unknown,
    this.gatewayUrl,
    this.gatewayStatus = GatewaySourceStatus.unknown,
  });

  factory Site.fromJson(Map<String, dynamic> json) => Site(
    key: json['key']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    type: switch (json['type']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value) ?? 3,
      _ => 3,
    },
    api: json['api']?.toString() ?? '',
    searchable: _boolLike(json['searchable'], defaultValue: true),
    isEnabled: true,
    sourceKind: _sourceKindFromTvBox(json),
  );

  /// 从简单的 API URL 创建 Site（用于直接输入 CMS 地址的场景）
  factory Site.fromUrl(String url, {String? name}) => Site(
    key: url.hashCode.toString(),
    name: name ?? url.split('/').where((s) => s.isNotEmpty).lastOrNull ?? url,
    type: 3,
    api: url,
    sourceKind: SiteSourceKind.cms,
  );

  factory Site.fromGateway({
    required String gatewayUrl,
    required String key,
    required String name,
    required String apiPath,
    required SiteSourceKind kind,
    required GatewaySourceStatus status,
    bool searchable = true,
  }) {
    final normalizedGateway = gatewayUrl.endsWith('/')
        ? gatewayUrl.substring(0, gatewayUrl.length - 1)
        : gatewayUrl;
    final baseUri = Uri.parse('$normalizedGateway/');
    final resolvedApi = baseUri.resolve(apiPath).toString();
    return Site(
      // 保留 v1 的 key 前缀，避免已保存的 Bridge 插件选择失效。
      key: 'bridge_$key',
      name: name,
      type: kind == SiteSourceKind.jar ? 4 : 3,
      api: resolvedApi,
      searchable: searchable,
      sourceKind: kind,
      gatewayUrl: normalizedGateway,
      gatewayStatus: status,
    );
  }

  /// 从 JAR Bridge /api/list 返回的 source 创建 Site
  factory Site.fromBridge({
    required String bridgeUrl,
    required String key,
    required String name,
    required String apiPath,
  }) {
    return Site.fromGateway(
      gatewayUrl: bridgeUrl,
      key: key,
      name: name,
      apiPath: apiPath,
      kind: SiteSourceKind.jar,
      status: GatewaySourceStatus.ready,
    );
  }

  /// TVBox 的 type=4 只表示 JAR 插件，并不代表它已能通过本项目 Bridge
  /// 访问。只有由 `/api/list` 创建、携带 bridgeUrl 的站点才是真正的 Bridge。
  bool get isGateway => gatewayUrl?.isNotEmpty ?? false;

  /// v1 兼容 getter；新代码使用 [gatewayUrl] / [isGateway]。
  String? get bridgeUrl => gatewayUrl;

  bool get isBridge => isGateway;

  static SiteSourceKind _sourceKindFromTvBox(Map<String, dynamic> json) {
    final type = switch (json['type']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value) ?? 3,
      _ => 3,
    };
    final api = json['api']?.toString().toLowerCase() ?? '';
    if (type == 4 || api.startsWith('csp_')) {
      return SiteSourceKind.jar;
    }
    if (api.startsWith('http') && !api.endsWith('.js')) {
      return SiteSourceKind.cms;
    }
    return SiteSourceKind.unknown;
  }

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
}
