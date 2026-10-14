/// Each release publishes an immutable APK URL and an update manifest.
/// A mirror may be selected at build time without changing the update protocol.
class AppUpdates {
  static const manifestUrl = String.fromEnvironment(
    'STREAMBOX_UPDATE_URL',
    defaultValue:
        'https://github.com/huangj17/StreamBox-APP/releases/latest/download/update.json',
  );
  static const maxApkBytes = 512 * 1024 * 1024;

  static Uri requireHttps(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('更新地址必须是有效的 HTTPS 地址');
    }
    return uri;
  }
}
