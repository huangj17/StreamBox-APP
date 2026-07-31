/// 片源站点，来自 TVBox 配置 JSON 的 sites 数组
class Site {
  final String key;
  final String name;
  final int type; // 0=XML, 1=JSON旧, 3=JSON主流, 4=TVBox JAR
  final String api;
  final bool searchable;
  final bool isEnabled;
  final String? bridgeUrl;

  const Site({
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    this.searchable = true,
    this.isEnabled = true,
    this.bridgeUrl,
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
    searchable: (json['searchable'] ?? 1) == 1,
    isEnabled: true,
  );

  /// 从简单的 API URL 创建 Site（用于直接输入 CMS 地址的场景）
  factory Site.fromUrl(String url, {String? name}) => Site(
    key: url.hashCode.toString(),
    name: name ?? url.split('/').where((s) => s.isNotEmpty).lastOrNull ?? url,
    type: 3,
    api: url,
  );

  /// 从 JAR Bridge /api/list 返回的 source 创建 Site
  factory Site.fromBridge({
    required String bridgeUrl,
    required String key,
    required String name,
    required String apiPath,
  }) {
    final baseUrl = bridgeUrl.endsWith('/')
        ? bridgeUrl.substring(0, bridgeUrl.length - 1)
        : bridgeUrl;
    return Site(
      key: 'bridge_$key',
      name: name,
      type: 4,
      api: '$baseUrl$apiPath',
      bridgeUrl: baseUrl,
    );
  }

  /// TVBox 的 type=4 只表示 JAR 插件，并不代表它已能通过本项目 Bridge
  /// 访问。只有由 `/api/list` 创建、携带 bridgeUrl 的站点才是真正的 Bridge。
  bool get isBridge => bridgeUrl?.isNotEmpty ?? false;
}
