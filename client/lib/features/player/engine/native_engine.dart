import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'video_engine.dart';

/// 移动/TV 端播放引擎：基于 video_player
///
/// - Android：走 Media3 ExoPlayer，系统 MediaCodec 硬解
/// - iOS：走 AVPlayer
/// - 桌面：未支持（工厂层不会选到这里）
///
/// HLS 多码率：open 时并发拉取 master playlist 解析
/// `#EXT-X-STREAM-INF` 得到画质列表（同时记录每个档位的 sub-playlist URL）。
/// video_player 没有轨道选择 API，手动切画质通过 reopen sub-playlist URL
/// 实现（保留播放位置 + 播放状态）。
class NativeEngine implements VideoEngine {
  VideoPlayerController? _controller;
  Timer? _posTimer;
  // ExoPlayer/AVPlayer 有内部重试机制，瞬态错误（网络抖动、HLS master 首次
  // TLS 失败等）通常 1-2s 内自恢复。这里做 2.5s 去抖：收到 hasError 不立
  // 即冒泡，延迟后若 duration/isPlaying 显示实际已播放，则丢弃。
  Timer? _errorDebounceTimer;

  // 当前打开的 master / 源 URL（切画质或切 auto 时重开它）
  String _masterUrl = '';
  // quality.id → sub-playlist URL（仅 HLS master 有效）
  final Map<String, String> _qualityUrlById = {};

  VideoQuality _currentQuality = const VideoQuality.auto();

  // 去重 emit 的上一次值
  bool? _lastPlaying;
  bool? _lastBuffering;
  Duration? _lastPosition;
  Duration? _lastDuration;
  Duration? _lastBuffered;
  String? _lastError;

  // 流
  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _bufferedCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _qualitiesCtrl = StreamController<List<VideoQuality>>.broadcast();
  final _currentQualityCtrl = StreamController<VideoQuality>.broadcast();

  // Widget 重建触发器（controller 切换时通知）
  final _controllerNotifier = ValueNotifier<VideoPlayerController?>(null);

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
  Future<void> open(String url) async {
    _masterUrl = url;
    _qualityUrlById.clear();
    _currentQuality = const VideoQuality.auto();
    _qualitiesCtrl.add(const []);
    _currentQualityCtrl.add(const VideoQuality.auto());

    // 异步嗅探 HLS 画质列表（不阻塞播放）
    unawaited(_probeQualities(url));

    await _openUrl(url);
  }

  /// 内部：打开指定 URL（切画质时复用），保留当前位置 + 播放状态
  Future<void> _openUrl(String url, {Duration? resumePosition}) async {
    await _disposeController(keepListeners: true);
    _resetCachedState();
    _bufferingCtrl.add(true);

    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    _controllerNotifier.value = controller;

    controller.addListener(_onControllerChanged);

    try {
      await controller.initialize().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw TimeoutException('打开视频超时（20s）');
        },
      );
    } catch (e) {
      _errorCtrl.add(e.toString());
      return;
    }

    final d = controller.value.duration;
    if (d > Duration.zero) {
      _lastDuration = d;
      _durationCtrl.add(d);
    }

    if (resumePosition != null && resumePosition > Duration.zero) {
      try {
        await controller.seekTo(resumePosition);
      } catch (_) {}
    }

    _startPositionTimer();

    try {
      await controller.play();
    } catch (e) {
      _errorCtrl.add(e.toString());
    }
  }

  void _onControllerChanged() {
    final v = _controller?.value;
    if (v == null) return;

    if (v.hasError) {
      final msg = v.errorDescription ?? 'Unknown playback error';
      // 已经 emit 过这条错误，不再重复安排去抖
      if (msg == _lastError) return;
      // 去抖：延迟 2.5s 观察 ExoPlayer 是否自恢复
      if (_errorDebounceTimer?.isActive ?? false) return;
      _errorDebounceTimer = Timer(const Duration(milliseconds: 2500), () {
        final now = _controller?.value;
        if (now == null) return;
        // 2.5s 后仍未拿到 duration 且未在播放 → 视为真实错误
        if (now.duration == Duration.zero && !now.isPlaying) {
          _lastError = msg;
          _errorCtrl.add(msg);
        }
      });
      return;
    }

    if (v.isPlaying != _lastPlaying) {
      _lastPlaying = v.isPlaying;
      _playingCtrl.add(v.isPlaying);
    }
    if (v.isBuffering != _lastBuffering) {
      _lastBuffering = v.isBuffering;
      _bufferingCtrl.add(v.isBuffering);
    }
    final d = v.duration;
    if (d > Duration.zero && d != _lastDuration) {
      _lastDuration = d;
      _durationCtrl.add(d);
    }
    // 缓冲位置：取所有 buffered 段的最大 end
    if (v.buffered.isNotEmpty) {
      var maxEnd = Duration.zero;
      for (final range in v.buffered) {
        if (range.end > maxEnd) maxEnd = range.end;
      }
      if (maxEnd != _lastBuffered) {
        _lastBuffered = maxEnd;
        _bufferedCtrl.add(maxEnd);
      }
    }
  }

  void _startPositionTimer() {
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final v = _controller?.value;
      if (v == null || !v.isInitialized) return;
      final p = v.position;
      if (p != _lastPosition) {
        _lastPosition = p;
        _positionCtrl.add(p);
      }
    });
  }

  void _resetCachedState() {
    _lastPlaying = null;
    _lastBuffering = null;
    _lastPosition = null;
    _lastDuration = null;
    _lastBuffered = null;
    _lastError = null;
    _errorDebounceTimer?.cancel();
    _errorDebounceTimer = null;
  }

  Future<void> _disposeController({bool keepListeners = false}) async {
    _posTimer?.cancel();
    _posTimer = null;
    _errorDebounceTimer?.cancel();
    _errorDebounceTimer = null;
    final old = _controller;
    _controller = null;
    _controllerNotifier.value = null;
    if (old != null) {
      old.removeListener(_onControllerChanged);
      await old.dispose();
    }
  }

  // ── HLS 画质嗅探 ──

  Future<void> _probeQualities(String url) async {
    if (!url.toLowerCase().contains('.m3u8')) return;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        responseType: ResponseType.plain,
      ));
      final resp = await dio.get<String>(url);
      final text = resp.data ?? '';
      if (!text.contains('#EXT-X-STREAM-INF')) return;
      final list = _parseMasterPlaylist(text, url);
      if (list.length > 1) {
        _qualitiesCtrl.add(list);
      }
    } catch (_) {
      // 嗅探失败不影响播放；画质菜单不显示
    }
  }

  /// 解析 master playlist：`#EXT-X-STREAM-INF: ...` 下一行为 sub-playlist URL
  List<VideoQuality> _parseMasterPlaylist(String text, String masterUrl) {
    final resolutionRe = RegExp(r'RESOLUTION=(\d+)x(\d+)');
    final bandwidthRe = RegExp(r'BANDWIDTH=(\d+)');
    final lines = text.split(RegExp(r'\r?\n'));
    final list = <VideoQuality>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      // URL 一般在下一非空非注释行
      String? subUrl;
      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j].trim();
        if (next.isEmpty) continue;
        if (next.startsWith('#')) continue;
        subUrl = next;
        break;
      }
      if (subUrl == null) continue;

      final attrs = line.substring('#EXT-X-STREAM-INF:'.length);
      final res = resolutionRe.firstMatch(attrs);
      final bw = bandwidthRe.firstMatch(attrs);
      if (res == null) continue;
      final w = int.tryParse(res.group(1) ?? '');
      final h = int.tryParse(res.group(2) ?? '');
      final b = int.tryParse(bw?.group(1) ?? '');
      if (w == null || h == null) continue;

      final absoluteUrl = _resolveUrl(masterUrl, subUrl);
      final quality = VideoQuality(
        id: '${w}x$h${b != null ? '@$b' : ''}',
        width: w,
        height: h,
        bitrate: b,
      );
      _qualityUrlById[quality.id] = absoluteUrl;
      list.add(quality);
    }

    // 去重（同尺寸保留 bitrate 最大的）+ 按高度倒序
    final byKey = <String, VideoQuality>{};
    for (final q in list) {
      final key = '${q.width}x${q.height}';
      final prev = byKey[key];
      if (prev == null || (q.bitrate ?? 0) > (prev.bitrate ?? 0)) {
        byKey[key] = q;
      }
    }
    final dedup = byKey.values.toList();
    dedup.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    return dedup;
  }

  String _resolveUrl(String base, String relative) {
    if (relative.startsWith('http://') || relative.startsWith('https://')) {
      return relative;
    }
    try {
      return Uri.parse(base).resolve(relative).toString();
    } catch (_) {
      return relative;
    }
  }

  // ── 动作 ──

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> playOrPause() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
  }

  @override
  Future<void> seek(Duration position) async => _controller?.seekTo(position);

  @override
  Future<void> setRate(double rate) async {
    // AVPlayer 支持 0.5~2.0；超出会 throw，clamp 保护
    final clamped = rate.clamp(0.5, 2.0);
    await _controller?.setPlaybackSpeed(clamped);
  }

  @override
  Future<void> setVolume(double v01) async {
    await _controller?.setVolume(v01.clamp(0.0, 1.0));
  }

  @override
  Future<void> setQuality(VideoQuality q) async {
    if (q.id == _currentQuality.id) return;
    // 保存当前位置 + 播放状态
    final pos = _controller?.value.position ?? Duration.zero;
    final targetUrl = q.isAuto
        ? _masterUrl
        : (_qualityUrlById[q.id] ?? _masterUrl);
    if (targetUrl.isEmpty) return;

    _currentQuality = q;
    _currentQualityCtrl.add(q);

    await _openUrl(targetUrl, resumePosition: pos);
  }

  @override
  Widget buildVideoView() {
    return ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: _controllerNotifier,
      builder: (context, c, _) {
        if (c == null) {
          return const ColoredBox(color: Color(0xFF000000));
        }
        return AnimatedBuilder(
          animation: c,
          builder: (context, _) {
            if (!c.value.isInitialized) {
              return const ColoredBox(color: Color(0xFF000000));
            }
            return Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Future<void> dispose() async {
    await _disposeController();
    _controllerNotifier.dispose();
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _bufferingCtrl.close();
    await _bufferedCtrl.close();
    await _playingCtrl.close();
    await _errorCtrl.close();
    await _qualitiesCtrl.close();
    await _currentQualityCtrl.close();
  }
}
