import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // NOTE: iOS 暂不注册 `com.streambox/platform` MethodChannel（rxBytes 用于网速）。
  // Dart 侧 NetworkSpeedMonitor 只在 Platform.isAndroid 时轮询，iOS 不会触发
  // MissingPluginException。UI 上 iOS 显示加载秒数、不显示网速数字；Android 完整。
  // 需要补 iOS 网速时可在此注册 channel + 用 getifaddrs 读 en*/pdp_ip* 的 ifi_ibytes。
}
