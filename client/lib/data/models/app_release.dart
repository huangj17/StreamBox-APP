import '../../core/config/app_updates.dart';

class AppRelease {
  final String packageName;
  final String versionName;
  final int versionCode;
  final String downloadUrl;
  final int size;
  final String sha256;
  final String certificateSha256;
  final int minSdk;
  final String releaseNotes;

  const AppRelease({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.downloadUrl,
    required this.size,
    required this.sha256,
    required this.certificateSha256,
    required this.minSdk,
    required this.releaseNotes,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    String string(String key, {int maxLength = 2048}) {
      final value = json[key];
      if (value is! String || value.isEmpty || value.length > maxLength) {
        throw FormatException('更新信息中的 $key 无效');
      }
      return value;
    }

    int integer(String key, int maximum) {
      final value = json[key];
      if (value is! int || value <= 0 || value > maximum) {
        throw FormatException('更新信息中的 $key 无效');
      }
      return value;
    }

    String digest(String key) {
      final value = string(key, maxLength: 64).toLowerCase();
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
        throw FormatException('更新信息中的 $key 无效');
      }
      return value;
    }

    if (json['schemaVersion'] != 1) {
      throw const FormatException('不支持的更新信息格式');
    }
    final url = string('downloadUrl');
    AppUpdates.requireHttps(url);
    final notes = json['releaseNotes'] ?? '';
    if (notes is! String || notes.length > 16000) {
      throw const FormatException('更新说明无效');
    }
    return AppRelease(
      packageName: string('packageName', maxLength: 200),
      versionName: string('versionName', maxLength: 100),
      versionCode: integer('versionCode', 2147483647),
      downloadUrl: url,
      size: integer('size', AppUpdates.maxApkBytes),
      sha256: digest('sha256'),
      certificateSha256: digest('certificateSha256'),
      minSdk: integer('minSdk', 1000),
      releaseNotes: notes,
    );
  }

  Map<String, Object> installationArguments(String path) => {
    'path': path,
    'packageName': packageName,
    'versionName': versionName,
    'versionCode': versionCode,
    'size': size,
    'sha256': sha256,
    'certificateSha256': certificateSha256,
  };
}
