import 'package:flutter/widgets.dart';

/// HLS 画质档位（或单码率的唯一档位 / auto）
class VideoQuality {
  final String id; // 'auto' 或 引擎内部标识（如 "${w}x${h}@${bitrate}"）
  final int? width;
  final int? height;
  final int? bitrate; // bits per second

  const VideoQuality({
    required this.id,
    this.width,
    this.height,
    this.bitrate,
  });

  const VideoQuality.auto()
      : id = 'auto',
        width = null,
        height = null,
        bitrate = null;

  bool get isAuto => id == 'auto';

  @override
  bool operator ==(Object other) =>
      other is VideoQuality && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 播放引擎抽象
///
/// 双实现：
/// - [MediaKitEngine] 桌面（libmpv）
/// - [NativeEngine]   Android / iOS（video_player / ExoPlayer / AVPlayer）
abstract class VideoEngine {
  // ── 状态流（全部 Dart 原生类型，不暴露底层） ──
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get bufferingStream;

  /// 已缓冲到的位置（用于进度条上的缓冲指示）
  Stream<Duration> get bufferedStream;

  Stream<bool> get playingStream;
  Stream<String> get errorStream;

  /// HLS 多码率列表。空列表表示无多码率或嗅探失败。
  Stream<List<VideoQuality>> get qualitiesStream;

  /// 当前生效的画质（auto 或具体档位）。
  Stream<VideoQuality> get currentQualityStream;

  // ── 动作 ──
  Future<void> open(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);

  /// 音量 0.0 ~ 1.0
  Future<void> setVolume(double v01);

  /// 切画质；传 [VideoQuality.auto] 交还 ABR。
  Future<void> setQuality(VideoQuality q);

  Future<void> dispose();

  /// 视频 Widget（各引擎自带 Texture / PlatformView）。
  /// 默认全屏填充，外层用 [Positioned.fill] 包裹。
  Widget buildVideoView();
}
