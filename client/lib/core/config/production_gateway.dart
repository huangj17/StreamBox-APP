/// The existing production Bridge. This identifies its transport and plugins;
/// membership/order/enabled state still come entirely from the official JSON.
class ProductionGateway {
  static const url = 'http://1.14.171.39:9978';
  static const pluginKeys = {'jianpian', 'ikanbot', 'ysj'};

  static bool isOrigin(Uri uri) =>
      uri.scheme == 'http' &&
      uri.host == '1.14.171.39' &&
      uri.port == 9978 &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment;

  static String? pluginKey(Uri uri) {
    if (!isOrigin(uri) || uri.hasQuery) return null;
    final match = RegExp(r'^/api/([a-z]+)/?$').firstMatch(uri.path);
    final key = match?.group(1);
    return pluginKeys.contains(key) ? key : null;
  }

  static bool isApi(Uri uri) {
    if (!isOrigin(uri)) return false;
    final match = RegExp(r'^/api/([a-z]+)(/play)?/?$').firstMatch(uri.path);
    return match != null && pluginKeys.contains(match.group(1));
  }

  static bool isRoot(Uri uri) =>
      isOrigin(uri) && (uri.path.isEmpty || uri.path == '/') && !uri.hasQuery;

  /// A legacy HTTP request may only redirect within its original endpoint.
  static void validateRedirect(Uri original, Uri next) {
    if (!isOrigin(next) ||
        next.path.replaceFirst(RegExp(r'/$'), '') !=
            original.path.replaceFirst(RegExp(r'/$'), '')) {
      throw const FormatException('生产片源不允许跳转到其他服务或接口');
    }
  }
}
