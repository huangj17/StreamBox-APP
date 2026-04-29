import 'dart:io' show Platform;

import 'media_kit_engine.dart';
import 'native_engine.dart';
import 'video_engine.dart';

/// 按平台创建播放引擎
///
/// - 桌面（macOS / Windows / Linux）：[MediaKitEngine]（libmpv）
/// - Android / iOS（含 Android TV）：[NativeEngine]（ExoPlayer / AVPlayer 硬解）
VideoEngine createVideoEngine({required bool hardwareDecode}) {
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    return MediaKitEngine(hardwareDecode: hardwareDecode);
  }
  return NativeEngine();
}
