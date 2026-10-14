import '../../core/network/url_policy.dart';
import 'live_channel.dart';

/// Authoritative M3U subscription list, separate from the VOD catalog.
class LiveSourceCatalog {
  final List<LiveSubscription> subscriptions;
  const LiveSourceCatalog(this.subscriptions);
  factory LiveSourceCatalog.fromJson(Object? json) {
    if (json is! List || json.length > 200) {
      throw const FormatException('直播配置需要 JSON 数组，最多 200 个订阅');
    }
    final result = <LiveSubscription>[];
    final ids = <String>{};
    final urls = <String>{};
    for (final row in json) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('直播订阅必须是对象');
      }
      final id = row['id'];
      final name = row['name'];
      final url = row['url'];
      final enabled = row['isEnabled'] ?? true;
      final fallback = row['fallbackUrls'] ?? <String>[];
      if (id is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id) ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 100 ||
          url is! String ||
          enabled is! bool ||
          fallback is! List ||
          fallback.length > 5) {
        throw const FormatException(
          '直播订阅需要有效的 id、name、url、isEnabled 和 fallbackUrls',
        );
      }
      final uri = requireLiveCatalogUrl(url);
      if (!ids.add(id) || !urls.add(uri.toString())) {
        throw const FormatException('直播订阅的 id 和 url 不能重复');
      }
      final mirrors = <String>[];
      for (final value in fallback) {
        if (value is! String) throw const FormatException('备用下载地址必须是字符串');
        final mirror = requireLiveCatalogUrl(value).toString();
        if (mirror != uri.toString() && !mirrors.contains(mirror)) {
          mirrors.add(mirror);
        }
      }
      result.add(
        LiveSubscription(
          id: id,
          name: name.trim(),
          url: uri.toString(),
          isEnabled: enabled,
          fallbackUrls: List.unmodifiable(mirrors),
        ),
      );
    }
    return LiveSourceCatalog(List.unmodifiable(result));
  }
  List<Map<String, dynamic>> toJson() => [
    for (final item in subscriptions) item.toJson(),
  ];
}

Uri requireLiveCatalogUrl(String url) {
  if (url.length > 2048) throw const FormatException('直播配置地址过长');
  final uri = UrlPolicy.requireConfigUrl(url);
  UrlPolicy.requireCatalogApiUrl(uri.toString());
  return uri;
}
