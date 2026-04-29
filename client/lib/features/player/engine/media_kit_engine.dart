import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'video_engine.dart';

/// 桌面端播放引擎：基于 media_kit / libmpv
///
/// 修复了旧代码 `vo: null` 的 bug（`vo=null` 是"禁用视频输出"而非"软解"）。
/// 现在 `vo` 固定为 `gpu`，硬解由 libmpv 属性 `hwdec` 控制。
class MediaKitEngine implements VideoEngine {
  final bool hardwareDecode;

  late final Player _player;
  late final VideoController _controller;

  // 流订阅
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _bufSub;
  StreamSubscription<Duration>? _bufferedSub;
  StreamSubscription<bool>? _playSub;
  StreamSubscription<String>? _errSub;
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<Track>? _trackSub;

  // 转发流
  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _bufferedCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _qualitiesCtrl = StreamController<List<VideoQuality>>.broadcast();
  final _currentQualityCtrl = StreamController<VideoQuality>.broadcast();

  // 画质 id → 原始 VideoTrack（setVideoTrack 需要原始对象）
  final Map<String, VideoTrack> _trackById = {};

  MediaKitEngine({required this.hardwareDecode}) {
    _player = Player(
      // bufferSize 对应 libmpv 的 demuxer-max-bytes/back-bytes，必须构造时传入
      // （后置 setProperty 对已开流不生效）。默认 32 MiB 对 HLS 多码率偏小。
      configuration: const PlayerConfiguration(
        vo: 'gpu',
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);
    _applyHwdec();
    _applyCacheTuning();
    _wireStreams();
  }

  Future<void> _applyHwdec() async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty('hwdec', hardwareDecode ? 'auto-safe' : 'no');
      }
    } catch (_) {
      // 属性设置失败不影响播放，libmpv 使用默认值
    }
  }

  /// 调优 libmpv 缓冲参数，改善起播速度和卡顿率。
  ///
  /// libmpv 的 `demuxer-readahead-secs` / `cache-secs` 默认仅 1s，对 HLS
  /// （2-6s 分片）极不友好，是卡顿主因。每个属性独立 try-catch，
  /// 失败回退默认值，不影响其他属性。
  Future<void> _applyCacheTuning() async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    const props = {
      'cache-secs': '30',
      'demuxer-readahead-secs': '20',
      // 显式设防止未来升级变 yes（yes 会等缓存填满才起播，拖慢首帧）
      'cache-pause-initial': 'no',
      // media_kit 默认 5s，HLS master 握手慢时易误判
      'network-timeout': '10',
    };
    for (final e in props.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (_) {
        // 单个属性失败不影响其他
      }
    }
  }

  void _wireStreams() {
    _posSub = _player.stream.position.listen(_positionCtrl.add);
    _durSub = _player.stream.duration.listen(_durationCtrl.add);
    _bufSub = _player.stream.buffering.listen(_bufferingCtrl.add);
    _bufferedSub = _player.stream.buffer.listen(_bufferedCtrl.add);
    _playSub = _player.stream.playing.listen(_playingCtrl.add);
    _errSub = _player.stream.error.listen((e) {
      if (e.isNotEmpty) _errorCtrl.add(e);
    });

    _tracksSub = _player.stream.tracks.listen((tracks) {
      // 缓存所有 track（包含 auto/no）以备后续 setVideoTrack 用
      for (final t in tracks.video) {
        _trackById[t.id] = t;
      }
      final usable = tracks.video
          .where((t) =>
              t.id != 'auto' &&
              t.id != 'no' &&
              t.w != null &&
              t.h != null)
          .toList();
      usable.sort((a, b) => (b.h ?? 0).compareTo(a.h ?? 0));
      _qualitiesCtrl.add(usable.map(_toQuality).toList(growable: false));
    });

    _trackSub = _player.stream.track.listen((track) {
      final v = track.video;
      if (v.id == 'auto' || v.id == 'no') {
        _currentQualityCtrl.add(const VideoQuality.auto());
      } else {
        final cached = _trackById[v.id] ?? v;
        _currentQualityCtrl.add(_toQuality(cached));
      }
    });
  }

  VideoQuality _toQuality(VideoTrack t) {
    if (t.id == 'auto' || t.id == 'no') return const VideoQuality.auto();
    return VideoQuality(
      id: t.id,
      width: t.w,
      height: t.h,
    );
  }

  @override
  Stream<Duration> get positionStream => _positionCtrl.stream;

  @override
  Stream<Duration> get durationStream => _durationCtrl.stream;

  @override
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;

  @override
  Stream<Duration> get bufferedStream => _bufferedCtrl.stream;

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  Stream<String> get errorStream => _errorCtrl.stream;

  @override
  Stream<List<VideoQuality>> get qualitiesStream => _qualitiesCtrl.stream;

  @override
  Stream<VideoQuality> get currentQualityStream =>
      _currentQualityCtrl.stream;

  @override
  Future<void> open(String url) => _player.open(Media(url));

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setVolume(double v01) =>
      _player.setVolume((v01.clamp(0.0, 1.0)) * 100);

  @override
  Future<void> setQuality(VideoQuality q) {
    if (q.isAuto) return _player.setVideoTrack(VideoTrack.auto());
    final t = _trackById[q.id];
    if (t != null) return _player.setVideoTrack(t);
    return Future.value();
  }

  @override
  Widget buildVideoView() {
    return Video(
      controller: _controller,
      controls: NoVideoControls,
    );
  }

  @override
  Future<void> dispose() async {
    await _posSub?.cancel();
    await _durSub?.cancel();
    await _bufSub?.cancel();
    await _bufferedSub?.cancel();
    await _playSub?.cancel();
    await _errSub?.cancel();
    await _tracksSub?.cancel();
    await _trackSub?.cancel();
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _bufferingCtrl.close();
    await _bufferedCtrl.close();
    await _playingCtrl.close();
    await _errorCtrl.close();
    await _qualitiesCtrl.close();
    await _currentQualityCtrl.close();
    await _player.dispose();
  }
}
