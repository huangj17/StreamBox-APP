import 'dart:async';

import 'package:dio/dio.dart';
import 'package:streambox/data/models/app_release.dart';
import 'package:streambox/data/updates/app_update_repository.dart';

final testRelease = AppRelease(
  packageName: 'com.streambox.streambox',
  versionName: '0.4.1',
  versionCode: 5,
  downloadUrl: 'https://downloads.example/streambox.apk',
  size: 1024 * 1024,
  sha256: 'ab' * 32,
  certificateSha256: 'cd' * 32,
  minSdk: 23,
  releaseNotes: List.generate(30, (i) => '更新说明 $i：优化电视遥控操作').join('\n'),
);

class FakeAppUpdateRepository implements AppUpdateRepository {
  @override
  bool supported = true;
  UpdateCheckResult result = UpdateCheckResult('0.4.0', testRelease);
  Completer<UpdateCheckResult>? pendingCheck;
  Completer<String>? pendingDownload;
  Object? checkError;
  Object? verifyError;
  Object? installError;
  bool permission = true;
  bool installResult = false;
  int checkCount = 0;
  int downloadCount = 0;
  int installCount = 0;
  int verifyCount = 0;
  int settingsCount = 0;
  final removed = <String>[];
  void Function(int)? progress;
  CancelToken? downloadToken;

  @override
  Future<UpdateCheckResult> check(CancelToken token) async {
    checkCount++;
    if (checkError != null) throw checkError!;
    return pendingCheck == null ? result : await pendingCheck!.future;
  }

  @override
  Future<String> download(
    AppRelease release,
    CancelToken token,
    void Function(int bytes) onProgress,
  ) async {
    downloadCount++;
    progress = onProgress;
    downloadToken = token;
    return pendingDownload == null
        ? '/updates/verified.apk'
        : await pendingDownload!.future;
  }

  @override
  Future<void> verify(AppRelease release, String path) async {
    verifyCount++;
    if (verifyError != null) throw verifyError!;
  }

  @override
  Future<bool> canInstall() async => permission;

  @override
  Future<void> openPermissionSettings() async {
    settingsCount++;
  }

  @override
  Future<bool> install(AppRelease release, String path) async {
    installCount++;
    if (installError != null) throw installError!;
    return installResult;
  }

  @override
  Future<void> remove(String path) async {
    removed.add(path);
  }

  @override
  void dispose() {}
}
