import 'site.dart';

/// TVBox JSON 配置文件模型
class SourceConfig {
  final String? spider;
  final List<Site> sites;
  final List<LiveSource> lives;
  final List<ParseRule> parses;

  const SourceConfig({
    this.spider,
    required this.sites,
    this.lives = const [],
    this.parses = const [],
  });

  factory SourceConfig.fromJson(Map<String, dynamic> json) {
    return SourceConfig(
      spider: json['spider'] as String?,
      sites: (json['sites'] as List<dynamic>? ?? [])
          .map((e) => Site.fromJson(e as Map<String, dynamic>))
          .toList(),
      lives: (json['lives'] as List<dynamic>? ?? [])
          .map((e) => LiveSource.fromJson(e as Map<String, dynamic>))
          .toList(),
      parses: (json['parses'] as List<dynamic>? ?? [])
          .map((e) => ParseRule.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 筛选出标准苹果 CMS 站点（api 是 http 开头，非 csp_ 或 js 脚本）
  List<Site> get cmsSites => sites.where((s) {
        final api = s.api.toLowerCase();
        return api.startsWith('http') && !api.endsWith('.js');
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
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        playerType: json['playerType'] as int? ?? 0,
      );
}

/// 解析线路
class ParseRule {
  final String name;
  final String url;

  const ParseRule({required this.name, required this.url});

  factory ParseRule.fromJson(Map<String, dynamic> json) => ParseRule(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
}
