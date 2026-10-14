import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/app_release.dart';
import '../../data/updates/app_update_repository.dart';

final appUpdateRepositoryProvider = Provider<AppUpdateRepository>((ref) {
  final repository = AndroidAppUpdateRepository();
  ref.onDispose(repository.dispose);
  return repository;
});

final appUpdateProvider =
    StateNotifierProvider<AppUpdateController, AppUpdateState>(
      (ref) => AppUpdateController(ref.watch(appUpdateRepositoryProvider)),
    );

enum UpdatePhase {
  idle,
  checking,
  current,
  available,
  downloading,
  verifying,
  ready,
  permissionRequired,
  installing,
  error,
}

class AppUpdateState {
  final bool supported;
  final UpdatePhase phase;
  final AppRelease? release;
  final String? apkPath;
  final String? message;
  final String? installedVersion;
  final int received;

  const AppUpdateState({
    this.supported = true,
    this.phase = UpdatePhase.idle,
    this.release,
    this.apkPath,
    this.message,
    this.installedVersion,
    this.received = 0,
  });

  bool get busy => {
    UpdatePhase.checking,
    UpdatePhase.downloading,
    UpdatePhase.verifying,
    UpdatePhase.installing,
  }.contains(phase);

  String get status =>
      message ??
      switch (phase) {
        UpdatePhase.idle => '可检查新版本',
        UpdatePhase.checking => '正在检查更新…',
        UpdatePhase.current => '当前已是最新版本',
        UpdatePhase.available => '发现新版本 v${release?.versionName}',
        UpdatePhase.downloading => '正在下载安装包…',
        UpdatePhase.verifying => '正在校验安装包…',
        UpdatePhase.ready => '安装包已校验，可以安装',
        UpdatePhase.permissionRequired => '请允许 StreamBox 安装应用，返回后继续升级',
        UpdatePhase.installing => '请在系统安装界面确认升级',
        UpdatePhase.error => '更新失败，请重试',
      };

  AppUpdateState copyWith({
    required UpdatePhase phase,
    String? message,
    int? received,
    String? apkPath,
  }) => AppUpdateState(
    supported: supported,
    phase: phase,
    release: release,
    installedVersion: installedVersion,
    apkPath: apkPath ?? this.apkPath,
    received: received ?? this.received,
    message: message,
  );
}

class AppUpdateController extends StateNotifier<AppUpdateState> {
  final AppUpdateRepository _repository;
  CancelToken? _token;
  int _operation = 0;
  bool _waitingForPermission = false;
  bool _openingSettings = false;

  AppUpdateController(this._repository)
    : super(AppUpdateState(supported: _repository.supported));

  bool _active(int operation) => mounted && operation == _operation;

  Future<void> check() async {
    if (!state.supported || state.busy) return;
    final previousPath = state.apkPath;
    final operation = ++_operation;
    final token = _token = CancelToken();
    state = AppUpdateState(
      phase: UpdatePhase.checking,
      installedVersion: state.installedVersion,
    );
    try {
      if (previousPath != null) await _repository.remove(previousPath);
      final result = await _repository.check(token);
      if (!_active(operation)) return;
      state = AppUpdateState(
        phase: result.release == null
            ? UpdatePhase.current
            : UpdatePhase.available,
        release: result.release,
        installedVersion: result.installedVersion,
      );
    } catch (error) {
      if (_active(operation)) {
        state = state.copyWith(
          phase: UpdatePhase.error,
          message: _message(error),
        );
      }
    }
  }

  void leaveDialog() {
    _waitingForPermission = false;
    cancelTransfer();
  }

  Future<void> download() async {
    final release = state.release;
    if (release == null || state.busy || state.apkPath != null) return;
    final operation = ++_operation;
    final token = _token = CancelToken();
    state = state.copyWith(phase: UpdatePhase.downloading, received: 0);
    String? path;
    var keep = false;
    try {
      path = await _repository.download(release, token, (bytes) {
        if (_active(operation)) {
          state = state.copyWith(
            phase: UpdatePhase.downloading,
            received: bytes,
          );
        }
      });
      if (!_active(operation)) return;
      state = state.copyWith(phase: UpdatePhase.verifying);
      await _repository.verify(release, path);
      if (!_active(operation)) return;
      keep = true;
      state = state.copyWith(phase: UpdatePhase.ready, apkPath: path);
    } catch (error) {
      if (_active(operation)) {
        state = state.copyWith(
          phase: UpdatePhase.error,
          message: _message(error),
        );
      }
    } finally {
      if (!keep && path != null) await _repository.remove(path);
    }
  }

  void cancelTransfer() {
    if (!{
      UpdatePhase.checking,
      UpdatePhase.downloading,
      UpdatePhase.verifying,
    }.contains(state.phase)) {
      return;
    }
    ++_operation;
    _token?.cancel('用户取消');
    state = state.copyWith(
      phase: state.release == null ? UpdatePhase.idle : UpdatePhase.available,
      received: 0,
    );
  }

  Future<void> install() async {
    final release = state.release;
    final path = state.apkPath;
    if (release == null || path == null || state.busy) return;
    final operation = ++_operation;
    state = state.copyWith(phase: UpdatePhase.installing);
    try {
      if (!await _repository.canInstall()) {
        if (_active(operation)) {
          state = state.copyWith(phase: UpdatePhase.permissionRequired);
        }
        return;
      }
      final installed = await _repository.install(release, path);
      if (!_active(operation)) return;
      state = state.copyWith(
        phase: UpdatePhase.ready,
        message: installed ? '安装完成，请重新打开 StreamBox' : '已取消安装，可再次安装',
      );
    } catch (error) {
      if (_active(operation)) {
        if (error is PlatformException && error.code == 'UPDATE_INVALID_APK') {
          await _repository.remove(path);
          if (!_active(operation)) return;
          state = AppUpdateState(
            release: release,
            installedVersion: state.installedVersion,
            phase: UpdatePhase.error,
            message: _message(error),
          );
        } else {
          state = state.copyWith(
            phase:
                error is PlatformException && error.code == 'UPDATE_PERMISSION'
                ? UpdatePhase.permissionRequired
                : UpdatePhase.error,
            message: _message(error),
          );
        }
      }
    }
  }

  Future<void> openPermissionSettings() async {
    if (state.phase != UpdatePhase.permissionRequired || _openingSettings) {
      return;
    }
    _openingSettings = true;
    _waitingForPermission = true;
    try {
      await _repository.openPermissionSettings();
    } catch (error) {
      _waitingForPermission = false;
      if (mounted) {
        state = state.copyWith(
          phase: UpdatePhase.permissionRequired,
          message: _message(error),
        );
      }
    } finally {
      _openingSettings = false;
    }
  }

  Future<void> resumed() async {
    if (!_waitingForPermission ||
        state.phase != UpdatePhase.permissionRequired) {
      return;
    }
    _waitingForPermission = false;
    // Installation was already requested before opening system settings.
    await install();
  }

  static String _message(Object error) {
    if (error is FormatException) return error.message;
    if (error is PlatformException) return error.message ?? '系统安装失败，请重试';
    if (error is DioException) {
      if (error.response?.statusCode == 404) return '暂未发布更新信息，请稍后重试';
      return '网络连接失败，请检查网络后重试';
    }
    return '更新失败，请检查网络和可用存储空间后重试';
  }

  @override
  void dispose() {
    ++_operation;
    _token?.cancel('更新服务关闭');
    super.dispose();
  }
}
