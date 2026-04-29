import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// 应用运行平台
enum AppPlatform {
  androidTv, // Android TV 盒子，遥控器操作
  windows,   // Windows 桌面，鼠标+键盘
  mobile,    // Android / iOS 手机，触摸操作（v2.0）
}

/// 输入方式
enum InputType {
  dpad,  // 遥控器方向键（TV）
  mouse, // 鼠标（Windows）
  touch, // 触摸（手机，v2.0）
}

/// 平台抽象层
class PlatformService {
  /// 与原生侧约定的 channel 名（详见 MainActivity.kt）
  static const _channel = MethodChannel('com.streambox/platform');

  /// 是否为 Android TV，由 [init] 在启动时通过 MethodChannel 查询并缓存。
  /// 未调用 [init] 时默认为 false（按手机处理）。
  static bool _isAndroidTvCached = false;

  /// App 启动时调用一次，查询 Android 设备的 UI 模式（TV vs 手机）。
  /// 仅在 Android 上有意义；其他平台无副作用。
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      final result = await _channel.invokeMethod<bool>('isTv');
      _isAndroidTvCached = result ?? false;
    } catch (_) {
      _isAndroidTvCached = false;
    }
  }

  static AppPlatform get current {
    if (Platform.isAndroid) {
      return _isAndroidTvCached ? AppPlatform.androidTv : AppPlatform.mobile;
    }
    if (Platform.isWindows) return AppPlatform.windows;
    if (Platform.isIOS) return AppPlatform.mobile;
    // macOS 开发环境视为 Windows（桌面端）
    if (Platform.isMacOS) return AppPlatform.windows;
    return AppPlatform.windows;
  }

  static InputType get inputType => switch (current) {
    AppPlatform.androidTv => InputType.dpad,
    AppPlatform.windows   => InputType.mouse,
    AppPlatform.mobile    => InputType.touch,
  };

  static bool get isTv => current == AppPlatform.androidTv;
  static bool get isDesktop => current == AppPlatform.windows;
  static bool get isMobile => current == AppPlatform.mobile;

  /// 是否需要焦点系统（TV 和 Windows 键盘模式需要，手机不需要）
  static bool get needsFocusSystem =>
      current == AppPlatform.androidTv || current == AppPlatform.windows;
}
