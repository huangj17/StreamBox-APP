import 'dart:io';
import '../config/official_sources.dart';

/// Untrusted configuration and CMS responses must not select arbitrary local
/// files/protocol handlers or literal private-network endpoints.
class UrlPolicy {
  /// A narrowly scoped exception for the configured official endpoint. Redirects
  /// may upgrade the same host/path to HTTPS, never select another HTTP target.
  static Uri requireOfficialConfigUrl(String raw) {
    final uri = _parse(raw);
    final configured = _parse(OfficialSources.url);
    final exact = uri == configured;
    final httpsUpgrade =
        configured.scheme == 'http' &&
        uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.host == configured.host &&
        uri.path == configured.path &&
        uri.query == configured.query;
    if ((!exact && !httpsUpgrade) ||
        !{'http', 'https'}.contains(uri.scheme) ||
        _isPrivateLiteral(uri.host) ||
        _isLoopbackHost(uri.host)) {
      throw const FormatException('官方配置只允许访问指定服务器的配置文件');
    }
    return uri;
  }

  static Uri requireConfigUrl(String raw) {
    final uri = _parse(raw);
    if (uri.scheme == 'https') return uri;
    if (uri.scheme == 'http' && _isLoopbackHost(uri.host)) return uri;
    throw const FormatException('配置源必须使用 HTTPS；仅本机地址允许 HTTP');
  }

  static Uri requireGatewayUrl(String raw) {
    final uri = _parse(raw);
    if (uri.scheme == 'https') return uri;
    if (uri.scheme == 'http' && _isLoopbackHost(uri.host)) return uri;
    throw const FormatException('远程 Gateway 必须使用 HTTPS');
  }

  static Uri requireCmsApiUrl(String raw, {bool allowLoopback = false}) {
    final uri = _parse(raw);
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('CMS API 只允许 HTTP(S) 地址');
    }
    if (uri.scheme == 'http' && !_isLoopbackHost(uri.host)) {
      throw const FormatException('远程 CMS API 必须使用 HTTPS');
    }
    if (!allowLoopback && _isPrivateLiteral(uri.host)) {
      throw const FormatException('CMS API 不允许访问本机或私网地址');
    }
    return uri;
  }

  static Uri requirePlaybackUrl(String raw) {
    final uri = _parse(raw);
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('播放地址只允许 HTTP(S) 协议');
    }
    if (_isPrivateLiteral(uri.host)) {
      throw const FormatException('播放地址不允许访问本机或私网地址');
    }
    return uri;
  }

  static bool isSafeCmsApi(String raw) {
    try {
      requireCmsApiUrl(raw);
      return true;
    } on FormatException {
      return false;
    }
  }

  static Uri _parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        uri.host.isEmpty) {
      throw const FormatException('URL 格式无效');
    }
    if (uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
      throw const FormatException('URL 不允许包含账号密码或 fragment');
    }
    return uri;
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    final address = InternetAddress.tryParse(normalized);
    return address?.isLoopback ?? false;
  }

  static bool _isPrivateLiteral(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null) return false;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0];
      final b = bytes[1];
      return a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          a >= 224;
    }
    return address.isLoopback ||
        address.isLinkLocal ||
        (bytes.isNotEmpty && (bytes[0] & 0xfe) == 0xfc) ||
        bytes.every((byte) => byte == 0);
  }
}
