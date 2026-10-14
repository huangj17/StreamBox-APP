import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../core/config/app_updates.dart';
import '../../core/network/bounded_response.dart';
import '../models/app_release.dart';

class UpdateCheckResult {
  final String installedVersion;
  final AppRelease? release;
  const UpdateCheckResult(this.installedVersion, this.release);
}

abstract interface class AppUpdateRepository {
  bool get supported;
  Future<UpdateCheckResult> check(CancelToken token);
  Future<String> download(
    AppRelease release,
    CancelToken token,
    void Function(int bytes) onProgress,
  );
  Future<void> verify(AppRelease release, String path);
  Future<bool> canInstall();
  Future<void> openPermissionSettings();
  Future<bool> install(AppRelease release, String path);
  Future<void> remove(String path);
  void dispose();
}

class AndroidAppUpdateRepository implements AppUpdateRepository {
  static const _channel = MethodChannel('com.streambox/updates');
  final Dio _dio;
  final String manifestUrl;
  String? _cacheDirectory;

  AndroidAppUpdateRepository({
    Dio? dio,
    this.manifestUrl = AppUpdates.manifestUrl,
  }) : _dio =
           dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));

  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<UpdateCheckResult> check(CancelToken token) async {
    AppUpdates.requireHttps(manifestUrl);
    final info = await _channel.invokeMapMethod<String, dynamic>('deviceInfo');
    if (info == null) throw const FormatException('无法读取当前应用版本');
    _cacheDirectory = info['cacheDirectory'] as String;
    final text = await getBoundedText(
      _dio,
      manifestUrl,
      headers: {'Cache-Control': 'no-cache'},
      maxBytes: 64 * 1024,
      receiveTimeout: const Duration(seconds: 15),
      cancelToken: token,
      redirectValidator: (uri) => AppUpdates.requireHttps(uri.toString()),
    );
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('更新信息不是 JSON 对象');
    }
    final release = AppRelease.fromJson(decoded);
    if (release.packageName != info['packageName']) {
      throw const FormatException('更新包与当前应用不匹配');
    }
    final installed = info['versionName'] as String;
    if (release.versionCode <= (info['versionCode'] as num).toInt()) {
      return UpdateCheckResult(installed, null);
    }
    if (release.minSdk > (info['sdkInt'] as num).toInt()) {
      throw const FormatException('新版本不支持当前 Android 系统');
    }
    final certificates = (info['certificates'] as List).cast<String>();
    if (!certificates.contains(release.certificateSha256)) {
      throw const FormatException('发布签名与当前应用不同，无法覆盖安装');
    }
    return UpdateCheckResult(installed, release);
  }

  /// Stream to a private, unique directory so cancelled transfers cannot delete
  /// or overwrite a later retry. Never buffer the entire APK in memory.
  @override
  Future<String> download(
    AppRelease release,
    CancelToken token,
    void Function(int bytes) onProgress,
  ) async {
    final root = _cacheDirectory;
    if (root == null) throw const FormatException('请先检查更新');
    final directory = await Directory(root).create(recursive: true);
    final transfer = await directory.createTemp('download-');
    final partial = File('${transfer.path}/update.part');
    RandomAccessFile? output;
    var completed = false;
    try {
      var uri = AppUpdates.requireHttps(release.downloadUrl);
      Response<ResponseBody> response;
      for (var redirects = 0; ; redirects++) {
        response = await _dio.get<ResponseBody>(
          uri.toString(),
          cancelToken: token,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: false,
            receiveTimeout: const Duration(seconds: 30),
            validateStatus: (status) =>
                status == 200 || {301, 302, 303, 307, 308}.contains(status),
          ),
        );
        if (response.statusCode == 200) break;
        await response.data?.stream.listen(null).cancel();
        final location = response.headers.value('location');
        if (redirects >= 5 || location == null) {
          throw const FormatException('安装包下载地址重定向无效');
        }
        uri = AppUpdates.requireHttps(uri.resolve(location).toString());
      }
      final body = response.data;
      if (body == null) throw const FormatException('安装包为空');
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (length != null && length != release.size) {
        await body.stream.listen(null).cancel();
        throw const FormatException('安装包大小与发布信息不一致');
      }
      output = await partial.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in body.stream) {
        _checkCancelled(token);
        received += chunk.length;
        if (received > release.size) {
          throw const FormatException('安装包超过预期大小');
        }
        await output.writeFrom(chunk);
        onProgress(received);
      }
      await output.close();
      output = null;
      _checkCancelled(token);
      if (received != release.size) {
        throw const FormatException('安装包下载不完整，请重试');
      }
      final digest = await sha256.bind(partial.openRead()).first;
      _checkCancelled(token);
      if (digest.toString() != release.sha256) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
      final apk = await partial.rename('${transfer.path}/update.apk');
      completed = true;
      return apk.path;
    } finally {
      await output?.close();
      if (!completed) await transfer.delete(recursive: true);
    }
  }

  @override
  Future<void> verify(AppRelease release, String path) => _channel
      .invokeMethod<void>('verifyApk', release.installationArguments(path));

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstallPackages') ?? false;

  @override
  Future<void> openPermissionSettings() =>
      _channel.invokeMethod<void>('openInstallPermissionSettings');

  @override
  Future<bool> install(AppRelease release, String path) async =>
      await _channel.invokeMethod<bool>(
        'installApk',
        release.installationArguments(path),
      ) ??
      false;

  @override
  Future<void> remove(String path) async {
    final file = File(path);
    if (await file.exists()) await file.parent.delete(recursive: true);
  }

  @override
  void dispose() => _dio.close(force: true);

  static void _checkCancelled(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
  }
}
