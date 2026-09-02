import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_kit_engine.dart';
import 'native_engine.dart';
import 'video_engine.dart';

/// 每个播放页创建自己的引擎；测试可替换工厂而不启动原生解码器。
final videoEngineFactoryProvider = Provider((_) => createVideoEngine);

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
