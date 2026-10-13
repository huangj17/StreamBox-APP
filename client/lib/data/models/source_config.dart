import 'site.dart';
import '../../core/network/url_policy.dart';

/// TVBox JSON 配置文件模型
class SourceConfig {
  final String? spider;
  final List<Site> sites;
  final List<LiveSource> lives;
  final List<ParseRule> parses;
  final String? configUrl;
  final Map<String, dynamic> options;

  const SourceConfig({
    this.spider,
    required this.sites,
    this.lives = const [],
    this.parses = const [],
    this.configUrl,
    this.options = const {},
  });

  factory SourceConfig.fromJson(
    Map<String, dynamic> json, {
    String? configUrl,
  }) {
    final base = configUrl ?? json['configUrl']?.toString();
    final spider = json['spider']?.toString();
    return SourceConfig(
      configUrl: base,
      options: Map.unmodifiable(json),
      spider: spider == null ? null : Site.resolveReference(spider, base),
      sites: (json['sites'] is List ? json['sites'] as List : const [])
          .whereType<Map>()
          .map(
            (e) => Site.fromJson(
              {
                ...Map<String, dynamic>.from(e),
                'runtimeConfig': {
                  'parses': json['parses'] ?? const [],
                  'flags': json['flags'] ?? const [],
                  'headers': json['headers'] ?? const [],
                  'rules': json['rules'] ?? const [],
                },
              },
              configUrl: base,
              defaultJar: spider,
            ),
          )
          .toList(),
      lives: (json['lives'] is List ? json['lives'] as List : const [])
          .whereType<Map>()
          .map((e) => LiveSource.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      parses: (json['parses'] is List ? json['parses'] as List : const [])
          .whereType<Map>()
          .map((e) => ParseRule.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  /// 筛选出标准苹果 CMS 站点（api 是 http 开头，非 csp_ 或 js 脚本）
  List<Site> get cmsSites => sites.where((s) {
    final api = s.api.toLowerCase();
    return !s.isJar &&
        s.isSupported &&
        UrlPolicy.isSafeCmsApi(s.api) &&
        !api.endsWith('.js');
  }).toList();
}

/// 直播源
class LiveSource {
  final String name;
  final String url;
  final int playerType;

  const LiveSource({
    required this.name,
    required this.url,
    this.playerType = 0,
  });

  factory LiveSource.fromJson(Map<String, dynamic> json) => LiveSource(
    name: json['name']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
    playerType: switch (json['playerType']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value) ?? 0,
      _ => 0,
    },
  );
}

/// 解析线路
class ParseRule {
  final String name;
  final String url;

  const ParseRule({required this.name, required this.url});

  factory ParseRule.fromJson(Map<String, dynamic> json) => ParseRule(
    name: json['name']?.toString() ?? '',
    url: json['url']?.toString() ?? '',
  );
}
