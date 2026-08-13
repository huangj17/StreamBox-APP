import 'site.dart';
import '../../core/network/url_policy.dart';

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
      spider: json['spider']?.toString(),
      sites: (json['sites'] is List ? json['sites'] as List : const [])
          .whereType<Map>()
          .map((e) => Site.fromJson(Map<String, dynamic>.from(e)))
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
    return !s.isBridge &&
        s.type != 4 &&
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
