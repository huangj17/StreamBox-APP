import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// 网速监视器
///
/// 通过 `com.streambox/platform` MethodChannel 轮询 native 侧累计下载字节数
/// （Android `TrafficStats.getUidRxBytes` / iOS `getifaddrs`），Dart 侧做 diff
/// 计算每秒下载字节数。`null` 表示平台不支持或读取失败。
///
/// 用途：播放卡住 / 缓冲时在 UI 上显示当前网速，让用户能判断是 CMS 源慢
/// 还是本地网络慢。
class NetworkSpeedMonitor {
  static const _channel = MethodChannel('com.streambox/platform');

  Timer? _timer;
  int? _lastBytes;
  DateTime? _lastAt;

  final _ctrl = StreamController<int?>.broadcast();

  /// 每秒 emit 一次下载速度（byte/s）。null = 平台不支持或首次采样中。
  Stream<int?> get stream => _ctrl.stream;

  Future<int?> _readRxBytes() async {
    try {
      final v = await _channel.invokeMethod<int>('rxBytes');
      return (v == null || v < 0) ? null : v;
    } catch (_) {
      return null;
    }
  }

  void start() {
    stop();
    _lastBytes = null;
    _lastAt = null;
    // 只有 Android 实现了 `rxBytes` MethodChannel。
    // iOS 暂不做（Flutter 3.27 iOS implicit engine 注册 channel 有启动崩溃问题，
    // 见 ios/Runner/AppDelegate.swift 注释）；桌面也不做。
    // 这些平台调用会触发 MissingPluginException 刷日志，直接不启动轮询。
    if (!Platform.isAndroid) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final bytes = await _readRxBytes();
      final now = DateTime.now();
      if (bytes == null) {
        _ctrl.add(null);
        return;
      }
      final lastBytes = _lastBytes;
      final lastAt = _lastAt;
      if (lastBytes != null && lastAt != null) {
        final dtMs = now.difference(lastAt).inMilliseconds;
        if (dtMs > 0) {
          // 保护：接口重置会得到负值
          final diff = bytes - lastBytes;
          if (diff >= 0) {
            _ctrl.add((diff * 1000 ~/ dtMs));
          }
        }
      }
      _lastBytes = bytes;
      _lastAt = now;
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    stop();
    await _ctrl.close();
  }

  /// 格式化为人类可读："128KB/s" / "1.2MB/s"
  static String format(int? bytesPerSec) {
    if (bytesPerSec == null) return '';
    if (bytesPerSec < 1024) return '${bytesPerSec}B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)}KB/s';
    }
    return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)}MB/s';
  }
}
