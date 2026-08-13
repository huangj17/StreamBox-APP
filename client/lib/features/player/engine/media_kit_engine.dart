import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/network/url_policy.dart';
import '../player_buffering.dart';
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
  Timer? _positionThrottleTimer;
  Timer? _bufferThrottleTimer;

  Duration? _pendingPosition;
  Duration? _pendingBuffer;
  Duration? _lastPosition;
  Duration? _lastBuffer;

  double _playbackRate = 1.0;
  int? _selectedBitrate;
  PlaybackBufferTuning? _appliedTuning;

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
      // 显式设防止未来升级变 yes（yes 会等缓存填满才起播，拖慢首帧）
      'cache-pause-initial': 'no',
      // media_kit 默认 5s，HLS master 握手慢时易误判
      'network-timeout': '10',
      // 软解时多线程加速（默认 1）；hwdec=auto-safe 时影响小
      'vd-lavc-threads': '4',
    };
    for (final e in props.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (_) {
        // 单个属性失败不影响其他
      }
    }
    await _applyDynamicCacheTuning(force: true);
  }

  Future<void> _applyDynamicCacheTuning({bool force = false}) async {
    final native = _player.platform;
    if (native is! NativePlayer) return;
    final tuning = PlaybackBufferTuning.forPlayback(
      playbackRate: _playbackRate,
      bitrate: _selectedBitrate,
    );
    if (!force && tuning == _appliedTuning) return;

    final props = {
      'cache-secs': '${tuning.cacheSeconds}',
      'demuxer-readahead-secs': '${tuning.readaheadSeconds}',
    };
    for (final property in props.entries) {
      try {
        await native.setProperty(property.key, property.value);
      } catch (_) {
        // 动态调优失败时继续沿用上一次或 libmpv 默认配置。
      }
    }
    _appliedTuning = tuning;
  }

  void _wireStreams() {
    _posSub = _player.stream.position.listen(_onPosition);
    _durSub = _player.stream.duration.distinct().listen(_durationCtrl.add);
    _bufSub = _player.stream.buffering.distinct().listen(_bufferingCtrl.add);
    _bufferedSub = _player.stream.buffer.listen(_onBuffer);
    _playSub = _player.stream.playing.distinct().listen(_playingCtrl.add);
    _errSub = _player.stream.error.listen((e) {
      if (e.isNotEmpty) _errorCtrl.add(e);
    });

    _tracksSub = _player.stream.tracks.listen((tracks) {
      // 缓存所有 track（包含 auto/no）以备后续 setVideoTrack 用
      for (final t in tracks.video) {
        _trackById[t.id] = t;
      }
      final usable = tracks.video
          .where(
            (t) => t.id != 'auto' && t.id != 'no' && t.w != null && t.h != null,
          )
          .toList();
      usable.sort((a, b) => (b.h ?? 0).compareTo(a.h ?? 0));
      _qualitiesCtrl.add(usable.map(_toQuality).toList(growable: false));
    });

    _trackSub = _player.stream.track.listen((track) {
      final v = track.video;
      if (v.id == 'auto' || v.id == 'no') {
        _selectedBitrate = null;
        _currentQualityCtrl.add(const VideoQuality.auto());
      } else {
        final cached = _trackById[v.id] ?? v;
        _selectedBitrate = cached.bitrate;
        _currentQualityCtrl.add(_toQuality(cached));
      }
      unawaited(_applyDynamicCacheTuning());
    });
  }

  void _onPosition(Duration value) {
    if (value == _lastPosition || value == _pendingPosition) return;
    _pendingPosition = value;
    if (_positionThrottleTimer != null) return;
    _emitPendingPosition();
    _positionThrottleTimer = Timer(const Duration(milliseconds: 250), () {
      _positionThrottleTimer = null;
      _emitPendingPosition();
    });
  }

  void _emitPendingPosition() {
    final value = _pendingPosition;
    _pendingPosition = null;
    if (value == null || value == _lastPosition) return;
    _lastPosition = value;
    _positionCtrl.add(value);
  }

  void _onBuffer(Duration value) {
    if (value == _lastBuffer || value == _pendingBuffer) return;
    _pendingBuffer = value;
    if (_bufferThrottleTimer != null) return;
    _emitPendingBuffer();
    _bufferThrottleTimer = Timer(const Duration(milliseconds: 250), () {
      _bufferThrottleTimer = null;
      _emitPendingBuffer();
    });
  }

  void _emitPendingBuffer() {
    final value = _pendingBuffer;
    _pendingBuffer = null;
    if (value == null || value == _lastBuffer) return;
    _lastBuffer = value;
    _bufferedCtrl.add(value);
  }

  VideoQuality _toQuality(VideoTrack t) {
    if (t.id == 'auto' || t.id == 'no') return const VideoQuality.auto();
    return VideoQuality(id: t.id, width: t.w, height: t.h, bitrate: t.bitrate);
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
  Stream<VideoQuality> get currentQualityStream => _currentQualityCtrl.stream;

  @override
  Future<void> open(String url, {Map<String, String>? headers}) {
    final validated = UrlPolicy.requirePlaybackUrl(url);
    return _player.open(Media(validated.toString(), httpHeaders: headers));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) async {
    _playbackRate = rate;
    await _player.setRate(rate);
    await _applyDynamicCacheTuning();
  }

  @override
  Future<void> setVolume(double v01) =>
      _player.setVolume((v01.clamp(0.0, 1.0)) * 100);

  @override
  Future<void> setQuality(VideoQuality q) async {
    _selectedBitrate = q.bitrate;
    await _applyDynamicCacheTuning();
    if (q.isAuto) {
      await _player.setVideoTrack(VideoTrack.auto());
      return;
    }
    final t = _trackById[q.id];
    if (t != null) await _player.setVideoTrack(t);
  }

  @override
  Widget buildVideoView() {
    return Video(controller: _controller, controls: NoVideoControls);
  }

  @override
  Future<void> dispose() async {
    _positionThrottleTimer?.cancel();
    _bufferThrottleTimer?.cancel();
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
