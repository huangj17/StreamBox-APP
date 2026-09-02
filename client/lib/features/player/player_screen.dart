import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/platform/platform_service.dart';
import '../../core/platform/network_speed_monitor.dart';
import '../../core/network/url_policy.dart';
import '../../data/models/episode.dart';
import '../../data/models/site.dart';
import '../../data/models/watch_history.dart';
import '../../data/local/history_storage.dart';
import '../../data/local/player_settings_storage.dart';
import '../home/providers/categories_provider.dart';
import 'engine/video_engine.dart';
import 'engine/video_engine_factory.dart';
import 'player_buffering.dart';
part 'player_widgets.dart';

bool _isConfirmKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.gameButtonA;

bool _isPlayPauseKey(LogicalKeyboardKey key) =>
    _isConfirmKey(key) ||
    key == LogicalKeyboardKey.space ||
    key == LogicalKeyboardKey.mediaPlayPause;

@immutable
class _LoadingUiState {
  final bool buffering;
  final bool recovering;
  final Duration position;
  final int waitingSeconds;
  final int? appRxBytesPerSecond;

  const _LoadingUiState({
    this.buffering = true,
    this.recovering = true,
    this.position = Duration.zero,
    this.waitingSeconds = 0,
    this.appRxBytesPerSecond,
  });

  bool get isInitialLoading =>
      (buffering || recovering) && position == Duration.zero;
  bool get isRebuffering =>
      (buffering || recovering) && position > Duration.zero;

  @override
  bool operator ==(Object other) =>
      other is _LoadingUiState &&
      other.buffering == buffering &&
      other.recovering == recovering &&
      other.position == position &&
      other.waitingSeconds == waitingSeconds &&
      other.appRxBytesPerSecond == appRxBytesPerSecond;

  @override
  int get hashCode => Object.hash(
    buffering,
    recovering,
    position,
    waitingSeconds,
    appRxBytesPerSecond,
  );
}

/// 全屏播放页
class PlayerScreen extends ConsumerStatefulWidget {
  final String videoId;
  final Site site;
  final String videoTitle;
  final String cover;
  final List<List<Episode>> episodeGroups;
  final List<String> sourceNames;
  final int initialGroupIndex;
  final int initialEpisodeIndex;
  final int initialPositionMs;
  final String? category;

  const PlayerScreen({
    super.key,
    required this.videoId,
    required this.site,
    required this.videoTitle,
    required this.cover,
    required this.episodeGroups,
    required this.sourceNames,
    this.initialGroupIndex = 0,
    this.initialEpisodeIndex = 0,
    this.initialPositionMs = 0,
    this.category,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WindowListener {
  late final VideoEngine _engine;
  late HistoryStorage _historyStorage;
  late PlayerSettingsStorage _playerSettings;

  late int _groupIndex;
  late int _episodeIndex;

  bool _controlsVisible = true;
  bool _isFullscreen = false;
  Timer? _hideTimer;

  // TV 焦点管理
  // _rootFocusNode：外层 Focus 的节点，控制栏隐藏时焦点回落到它，
  // 从而让外层 _handleKey 接管方向键
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'playerRoot');
  // _playPauseFocusNode：播放/暂停按钮的节点，显示控制栏时 TV 上自动聚焦到它
  final FocusNode _playPauseFocusNode = FocusNode(debugLabel: 'playPause');

  // 快进/快退长按加速
  Timer? _seekHoldTimer;
  int _seekHoldCount = 0; // 已触发次数，用于计算加速档位

  // 播放器状态
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero; // 已缓冲到的位置
  bool _buffering = true;
  bool _playing = false;
  bool _seeking = false; // 拖动进度条时暂停位置更新
  final _progressState = ValueNotifier(const PlaybackProgressState());
  final _loadingState = ValueNotifier(const _LoadingUiState());
  final _bufferMetrics = PlaybackBufferMetrics();

  // 视频画质（HLS 多码率切换）
  List<VideoQuality> _qualities = [];
  VideoQuality _currentQuality = const VideoQuality.auto();

  // 流订阅
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _bufSub;
  StreamSubscription<Duration>? _bufferedSub;
  StreamSubscription<bool>? _playSub;
  StreamSubscription<String>? _errSub;
  StreamSubscription<List<VideoQuality>>? _qualitiesSub;
  StreamSubscription<VideoQuality>? _currentQualitySub;

  // 播放失败信息（非空时显示错误遮罩）
  String? _error;
  Timer? _errorTimer; // 延迟显示错误，避免瞬态错误闪烁
  Timer? _stuckTimer; // 卡死超时：没有观察到播放时钟推进 → 自动报错可重试
  final _progressEvidence = PlaybackProgressEvidence();
  String _stuckMessage = '加载超时（30 秒未取到首帧），请尝试切换线路';

  // 加载 / 卡顿状态显示
  final _speedMonitor = NetworkSpeedMonitor();
  StreamSubscription<int?>? _speedSub;
  int? _speedBps; // 当前下载速度（byte/s）
  DateTime? _buffStartAt; // 最近一次进入缓冲的时间戳
  Timer? _buffTickTimer; // 每秒刷新"已加载 Ns"显示

  // 音量（0.0 ~ 1.0）
  double _volume = 1.0;
  // 倍速
  double _playbackSpeed = 1.0;

  // 续播：_resumePositionMs > 0 时，duration 确定后自动 seek
  int _resumePositionMs = 0;
  int _playRequestId = 0;

  // ── 计算属性 ──

  Episode get _current => widget.episodeGroups[_groupIndex][_episodeIndex];

  bool get _hasPrev => _episodeIndex > 0;
  bool get _hasNext =>
      _episodeIndex < widget.episodeGroups[_groupIndex].length - 1;

  String get _sourceName => widget.sourceNames.length > _groupIndex
      ? widget.sourceNames[_groupIndex]
      : '线路 ${_groupIndex + 1}';

  // ── 生命周期 ──

  @override
  void initState() {
    super.initState();
    _groupIndex = widget.initialGroupIndex;
    _episodeIndex = widget.initialEpisodeIndex;
    _historyStorage = ref.read(historyStorageProvider);
    _playerSettings = ref.read(playerSettingsStorageProvider);

    _engine = ref.read(videoEngineFactoryProvider)(
      hardwareDecode: _playerSettings.hardwareDecode,
    );

    // 应用默认倍速
    _playbackSpeed = _playerSettings.defaultSpeed;
    if (_playbackSpeed != 1.0) {
      _engine.setRate(_playbackSpeed);
    }

    _resumePositionMs = widget.initialPositionMs;

    _posSub = _engine.positionStream.listen((p) {
      if (!mounted || _seeking) return;
      _position = p;
      _publishProgressState();
      _observePlaybackProgress(p);
    });
    _durSub = _engine.durationStream.listen((d) {
      if (!mounted) return;
      _duration = d;
      _publishProgressState();
      // duration 只表示元数据已加载，不能据此认定首帧已渲染。
      if (_resumePositionMs > 0 && d.inMilliseconds > 0) {
        final target = Duration(milliseconds: _resumePositionMs);
        _expectRecoveryAt(target);
        _engine.seek(target);
        _resumePositionMs = 0;
      }
    });
    _bufSub = _engine.bufferingStream.listen((b) {
      if (!mounted) return;
      _setBuffering(b);
    });
    _bufferedSub = _engine.bufferedStream.listen((b) {
      if (!mounted) return;
      _buffered = b;
      _publishProgressState();
    });
    _playSub = _engine.playingStream.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
      // playing=true 可能早于首帧，首帧确认统一由 position 连续推进完成。
    });
    _qualitiesSub = _engine.qualitiesStream.listen((list) {
      if (!mounted) return;
      final isFirstDiscovery = _qualities.isEmpty && list.length > 1;
      setState(() => _qualities = list);
      if (isFirstDiscovery) {
        final best = list.first;
        final h = best.height ?? 0;
        final label = h >= 2160
            ? '4K'
            : h >= 1080
            ? '1080P'
            : h >= 720
            ? '720P'
            : '${h}P';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('当前源支持多画质切换（最高 $label）'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            backgroundColor: const Color(0xDD333333),
            margin: const EdgeInsets.only(bottom: 80, left: 20, right: 20),
          ),
        );
      }
    });
    _currentQualitySub = _engine.currentQualityStream.listen((q) {
      if (mounted) setState(() => _currentQuality = q);
    });

    _errSub = _engine.errorStream.listen((err) {
      if (!mounted || err.isEmpty) return;
      // 自动尝试下一线路（仅多线路时触发）
      if (widget.episodeGroups.length > 1) {
        final nextGroup = _groupIndex + 1;
        if (nextGroup < widget.episodeGroups.length) {
          final nextEps = widget.episodeGroups[nextGroup];
          final epIdx = _episodeIndex.clamp(0, nextEps.length - 1);
          if (nextEps[epIdx].url.isNotEmpty) {
            setState(() {
              _groupIndex = nextGroup;
              _episodeIndex = epIdx;
              _error = null;
            });
            _playCurrentEpisode();
            return;
          }
        }
      }
      // 延迟显示错误：给底层 1.5s 自恢复；若 position 继续推进，
      // _confirmPlaybackProgress 会清除瞬态错误。
      final errorMsg = err.isNotEmpty ? err : '播放失败';
      if (_playing) {
        _armStuckTimer(
          expectedPosition: _position,
          timeout: const Duration(seconds: 15),
          message: errorMsg,
        );
      }
      _errorTimer?.cancel();
      _errorTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted && (_progressEvidence.isArmed || !_playing)) {
          setState(() => _error = errorMsg);
        }
      });
    });

    // Android 的 TrafficStats 是应用级下行，仅在实际缓冲时采样；高频结果只
    // 刷新 loading 层，不触发整页重建。
    _speedSub = _speedMonitor.stream.listen((bps) {
      if (!mounted || !_buffering) return;
      _speedBps = bps;
      _publishLoadingState();
    });

    _buffStartAt = DateTime.now();
    _playCurrentEpisode();
    _scheduleHide();

    // 播放期间保持屏幕常亮：酷开等 Android TV ROM 屏保触发后会杀掉前台 App
    WakelockPlus.enable();
    unawaited(PlatformService.setKeepScreenOn(true));

    // TV：隐藏系统导航栏进入沉浸式全屏
    if (PlatformService.isTv) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    // 桌面：监听窗口全屏状态变化（macOS 绿色按钮 / Windows 最大化等）
    if (_isDesktopPlatform) {
      windowManager.addListener(this);
      windowManager.isFullScreen().then((v) {
        if (mounted) setState(() => _isFullscreen = v);
      });
    }
  }

  @override
  void deactivate() {
    // 在 ref 还可用时刷新首页「继续观看」行
    _saveHistory();
    ref.invalidate(watchHistoryProvider);
    super.deactivate();
  }

  @override
  void dispose() {
    _playRequestId++;
    _logBufferMetrics();
    WakelockPlus.disable();
    unawaited(PlatformService.setKeepScreenOn(false));
    _hideTimer?.cancel();
    _seekHoldTimer?.cancel();
    _errorTimer?.cancel();
    _stuckTimer?.cancel();
    _buffTickTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _bufSub?.cancel();
    _bufferedSub?.cancel();
    _playSub?.cancel();
    _errSub?.cancel();
    _qualitiesSub?.cancel();
    _currentQualitySub?.cancel();
    _speedSub?.cancel();
    _speedMonitor.dispose();
    _engine.dispose();
    _progressState.dispose();
    _loadingState.dispose();
    _rootFocusNode.dispose();
    _playPauseFocusNode.dispose();
    if (_isDesktopPlatform) windowManager.removeListener(this);
    if (PlatformService.isTv) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    // 移动端：若处于全屏状态（横屏），退出时恢复竖屏 + 系统 UI
    if (PlatformService.isMobile && _isFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  // ── 平台检测 ──

  bool get _isDesktopPlatform =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  bool get _usesLeanbackControls => PlatformService.isTv || _isDesktopPlatform;

  // ── WindowListener（桌面端全屏状态同步） ──

  @override
  void onWindowEnterFullScreen() {
    if (mounted) setState(() => _isFullscreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted) setState(() => _isFullscreen = false);
  }

  // ── 全屏切换 ──

  Future<void> _toggleFullscreen() async {
    if (_isDesktopPlatform) {
      await windowManager.setFullScreen(!_isFullscreen);
    } else if (PlatformService.isMobile) {
      // 移动端：在竖屏与横屏之间切换；全屏时隐藏状态栏 / 导航栏
      if (_isFullscreen) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } else {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
      if (mounted) setState(() => _isFullscreen = !_isFullscreen);
    }
    _showControls();
  }

  // ── 播放控制 ──

  void _publishProgressState() {
    final next = PlaybackProgressState(
      position: _position,
      duration: _duration,
      buffered: _buffered,
    );
    if (next != _progressState.value) _progressState.value = next;
    if (!_buffering) {
      _bufferMetrics.observeBufferAhead(next.bufferAhead);
    } else {
      _publishLoadingState();
    }
  }

  void _publishLoadingState() {
    final next = _LoadingUiState(
      buffering: _buffering,
      recovering: _progressEvidence.isArmed,
      position: _position,
      waitingSeconds: _bufferingSeconds(),
      appRxBytesPerSecond: _speedBps,
    );
    if (next != _loadingState.value) _loadingState.value = next;
  }

  void _setBuffering(bool value, {bool restartIndicators = false}) {
    final changed = _buffering != value;
    _buffering = value;
    final now = DateTime.now();
    if (changed) _bufferMetrics.onBufferingChanged(value, now);

    if (value) {
      if (restartIndicators) {
        _buffStartAt = now;
        _speedBps = null;
      } else {
        _buffStartAt ??= now;
      }
      if (changed || restartIndicators || _buffTickTimer == null) {
        _speedMonitor.start();
      }
      _buffTickTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _buffering) _publishLoadingState();
      });
    } else {
      _buffStartAt = null;
      _speedBps = null;
      _buffTickTimer?.cancel();
      _buffTickTimer = null;
      _speedMonitor.stop();
    }
    _publishLoadingState();
  }

  /// position 首次到达预期位置只作为基线；随后播放时钟继续推进，才算首帧
  /// 真正输出。这样续播 seek 的瞬时位置跳变不会提前关闭卡死检测。
  void _observePlaybackProgress(Duration position) {
    if (_progressEvidence.observe(position)) _confirmPlaybackProgress();
  }

  void _confirmPlaybackProgress() {
    _progressEvidence.disarm();
    _stuckTimer?.cancel();
    _stuckTimer = null;
    _publishLoadingState();
    _bufferMetrics.markFirstFrame(DateTime.now());
    _errorTimer?.cancel();
    if (_error != null && mounted) setState(() => _error = null);
  }

  void _expectRecoveryAt(Duration position) {
    _progressEvidence.expect(position);
  }

  /// 启动「播放时钟未推进」兜底。duration/playing 只能证明元数据或播放意图，
  /// 不能证明首帧已经渲染。
  void _armStuckTimer({
    Duration expectedPosition = Duration.zero,
    Duration timeout = const Duration(seconds: 30),
    String message = '加载超时（30 秒未取到首帧），请尝试切换线路',
  }) {
    _stuckTimer?.cancel();
    _progressEvidence.arm(expectedPosition);
    _stuckMessage = message;
    _publishLoadingState();
    _stuckTimer = Timer(timeout, () {
      if (!mounted) return;
      if (_progressEvidence.isArmed && _error == null) {
        setState(() => _error = _stuckMessage);
      }
    });
  }

  void _disarmStuckTimer() {
    _stuckTimer?.cancel();
    _stuckTimer = null;
    _progressEvidence.disarm();
    _publishLoadingState();
  }

  Future<void> _playCurrentEpisode() async {
    final requestId = ++_playRequestId;
    final episode = _current;
    var url = episode.url;
    var headers = episode.headers;
    if (url.isEmpty) return;
    _logBufferMetrics();
    _bufferMetrics.reset(DateTime.now());
    _errorTimer?.cancel();
    setState(() {
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffered = Duration.zero;
      _buffering = true;
      _error = null;
      _qualities = [];
      _currentQuality = const VideoQuality.auto();
    });
    _publishProgressState();
    _setBuffering(true, restartIndicators: true);
    _armStuckTimer();
    try {
      if (widget.site.isBridge && episode.requiresResolve) {
        final result = await ref
            .read(cmsApiProvider)
            .resolvePlayUrl(
              site: widget.site,
              flag: episode.sourceFlag,
              rawUrl: episode.url,
            );
        if (!mounted || requestId != _playRequestId) return;
        url = result.url;
        headers = result.headers;
      }
      url = UrlPolicy.requirePlaybackUrl(url).toString();
      await _engine.open(url, headers: headers);
    } catch (error) {
      if (!mounted || requestId != _playRequestId) return;
      _disarmStuckTimer();
      _setBuffering(false);
      setState(() => _error = '播放地址解析失败：$error');
    }
  }

  void _logBufferMetrics() {
    if (!kDebugMode || !_bufferMetrics.hasSession) return;
    debugPrint('播放缓存指标: ${_bufferMetrics.snapshot(DateTime.now())}');
  }

  void _switchEpisode(int groupIndex, int episodeIndex) {
    setState(() {
      _groupIndex = groupIndex;
      _episodeIndex = episodeIndex;
    });
    _playCurrentEpisode();
    _showControls();
  }

  void _seekRelative(Duration delta) {
    final ms = (_position + delta).inMilliseconds.clamp(
      0,
      _duration.inMilliseconds,
    );
    _seekTo(Duration(milliseconds: ms));
    _showControls();
  }

  void _seekTo(Duration position) {
    if (_playing) {
      _buffered = position;
      _publishProgressState();
      _armStuckTimer(
        expectedPosition: position,
        timeout: const Duration(seconds: 20),
        message: '跳转后恢复播放超时，请重试或切换线路',
      );
    }
    _engine.seek(position);
  }

  Future<void> _selectQuality(VideoQuality quality) async {
    if (quality == _currentQuality) return;
    if (_playing) {
      _buffered = _position;
      _publishProgressState();
      _armStuckTimer(
        expectedPosition: _position,
        timeout: const Duration(seconds: 20),
        message: '切换画质后恢复播放超时，请重试或切换线路',
      );
    }
    setState(() => _currentQuality = quality);
    try {
      await _engine.setQuality(quality);
    } catch (error) {
      if (!mounted) return;
      _disarmStuckTimer();
      setState(() => _error = '切换画质失败：$error');
    }
  }

  // ── 快进/快退长按加速 ──

  /// 按住时每次 seek 的秒数：按得越久档位越高
  /// 间隔 150ms，档位：0~3次 10s → 4~12次 30s → 13次+ 60s
  int _seekSeconds() {
    if (_seekHoldCount < 4) return 10; // 0~0.45s : ±10s
    if (_seekHoldCount < 13) return 30; // 0.6~1.8s: ±30s
    return 60; // 1.95s+  : ±60s
  }

  /// 按下时调用：立即 seek 一次，然后以 150ms 间隔持续加速 seek
  void _startSeekHold(bool forward) {
    _stopSeekHold();
    _seekHoldCount = 0;

    void doSeek() {
      _seekRelative(
        Duration(seconds: forward ? _seekSeconds() : -_seekSeconds()),
      );
      _seekHoldCount++;
    }

    doSeek(); // 按下立即响应
    _seekHoldTimer = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => doSeek(),
    );
  }

  /// 松开时调用：停止加速计时器
  void _stopSeekHold() {
    _seekHoldTimer?.cancel();
    _seekHoldTimer = null;
    _seekHoldCount = 0;
  }

  // ── 控制栏显示 / 隐藏 ──

  void _showControls() {
    _scheduleHide();
    final wasHidden = !_controlsVisible;
    if (wasHidden) setState(() => _controlsVisible = true);
    // TV 下：控制栏从隐藏变可见时，把焦点移到播放按钮，
    // 这样用户按方向键可在控制栏内自由导航
    if (wasHidden && PlatformService.isTv) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controlsVisible) {
          _playPauseFocusNode.requestFocus();
        }
      });
    }
  }

  /// 点击视频区域：切换控制栏显示/隐藏
  void _toggleControls() {
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  /// 隐藏控制栏，并把焦点交还给外层（TV）
  void _hideControls() {
    _hideTimer?.cancel();
    if (_controlsVisible) setState(() => _controlsVisible = false);
    if (PlatformService.isTv) _rootFocusNode.requestFocus();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) _hideControls();
    });
  }

  /// 鼠标移出播放器区域时快速隐藏（桌面端）
  void _onMouseExit(PointerExitEvent _) {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _hideControls();
    });
  }

  // ── 鼠标滚轮调节音量 ──

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
      setState(() => _volume = (_volume + delta).clamp(0.0, 1.0));
      _engine.setVolume(_volume);
      _showControls();
    }
  }

  // ── 右键菜单（桌面端） ──

  void _showContextMenu(TapUpDetails details) {
    final position = details.globalPosition;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      color: AppColors.surface,
      items: [
        // 倍速子菜单
        PopupMenuItem(
          value: 'speed',
          child: PopupMenuButton<double>(
            offset: const Offset(-160, 0),
            color: AppColors.surface,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.speed,
                  color: AppColors.secondaryText,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '倍速 ${_playbackSpeed}x',
                  style: const TextStyle(color: AppColors.primaryText),
                ),
              ],
            ),
            itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                .map(
                  (s) => PopupMenuItem(
                    value: s,
                    child: Text(
                      '${s}x',
                      style: TextStyle(
                        color: s == _playbackSpeed
                            ? AppColors.netflixRed
                            : AppColors.primaryText,
                      ),
                    ),
                  ),
                )
                .toList(),
            onSelected: (speed) {
              setState(() => _playbackSpeed = speed);
              _engine.setRate(speed);
            },
          ),
        ),
        // 画质切换（HLS 多码率时）
        if (_qualities.length > 1)
          PopupMenuItem(
            value: 'quality',
            child: Row(
              children: [
                const Icon(Icons.hd, color: AppColors.secondaryText, size: 18),
                const SizedBox(width: 8),
                Text(
                  '画质 ${_currentQuality.isAuto ? '自动' : '${_currentQuality.height ?? '?'}P'}',
                  style: const TextStyle(color: AppColors.primaryText),
                ),
              ],
            ),
          ),
        // 线路切换
        if (widget.episodeGroups.length > 1)
          ...List.generate(widget.episodeGroups.length, (i) {
            final name = widget.sourceNames.length > i
                ? widget.sourceNames[i]
                : '线路 ${i + 1}';
            return PopupMenuItem(
              value: 'source_$i',
              child: Row(
                children: [
                  Icon(
                    i == _groupIndex ? Icons.check : Icons.swap_horiz,
                    color: i == _groupIndex
                        ? AppColors.netflixRed
                        : AppColors.secondaryText,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    name,
                    style: TextStyle(
                      color: i == _groupIndex
                          ? AppColors.netflixRed
                          : AppColors.primaryText,
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    ).then((value) {
      if (value == null) return;
      if (value == 'quality' && _qualities.length > 1) {
        // 从右键菜单打开画质选择对话框
        _showQualityPicker();
      } else if (value.startsWith('source_')) {
        final idx = int.parse(value.substring(7));
        if (idx != _groupIndex) {
          _switchEpisode(
            idx,
            _episodeIndex.clamp(0, widget.episodeGroups[idx].length - 1),
          );
        }
      }
    });
  }

  // ── 画质选择对话框（右键菜单触发） ──

  void _showQualityPicker() {
    _trackDialog(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('画质切换', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PickerTile(
                title: '自动',
                selected: _currentQuality.isAuto,
                autofocus: _currentQuality.isAuto,
                onTap: () {
                  Navigator.of(context).pop();
                  _selectQuality(const VideoQuality.auto());
                },
              ),
              ..._qualities.map((q) {
                final selected = q.id == _currentQuality.id;
                return _PickerTile(
                  title: _qualityLabel(q),
                  subtitle: '${q.width}×${q.height}',
                  selected: selected,
                  autofocus: selected,
                  onTap: () {
                    Navigator.of(context).pop();
                    _selectQuality(q);
                  },
                );
              }),
            ],
          ),
        ),
      ),
      onComplete: () {
        if (mounted) _scheduleHide();
      },
    );
  }

  void _trackDialog(Future<void> dialog, {VoidCallback? onComplete}) {
    dialog.whenComplete(() => onComplete?.call());
  }

  void _showPlaybackOptionsPanel() {
    _hideTimer?.cancel();
    _trackDialog(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => Dialog(
          alignment: Alignment.bottomCenter,
          backgroundColor: const Color(0xFF151515),
          insetPadding: const EdgeInsets.fromLTRB(56, 0, 56, 44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('播放选项', style: AppTypography.headline2),
                      ),
                      Text(
                        _sourceName,
                        style: AppTypography.body.copyWith(
                          color: Colors.white54,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.md,
                    children: [
                      _OptionTile(
                        icon: Icons.video_library,
                        title: '选集',
                        subtitle: _current.name,
                        autofocus: true,
                        onTap: () {
                          Navigator.of(context).pop();
                          _showTvEpisodePicker();
                        },
                      ),
                      if (widget.episodeGroups.length > 1)
                        _OptionTile(
                          icon: Icons.swap_horiz,
                          title: '线路',
                          subtitle: _sourceName,
                          onTap: () {
                            Navigator.of(context).pop();
                            _showTvSourcePicker();
                          },
                        ),
                      if (_qualities.length > 1)
                        _OptionTile(
                          icon: Icons.hd,
                          title: '画质',
                          subtitle: _currentQuality.isAuto
                              ? '自动'
                              : _qualityLabel(_currentQuality),
                          onTap: () {
                            Navigator.of(context).pop();
                            _showTvQualityPicker();
                          },
                        ),
                      _OptionTile(
                        icon: Icons.speed,
                        title: '倍速',
                        subtitle: _speedLabel(_playbackSpeed),
                        onTap: () {
                          Navigator.of(context).pop();
                          _showTvSpeedPicker();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      onComplete: () {
        if (mounted) _scheduleHide();
      },
    );
  }

  void _showTvEpisodePicker() {
    final episodes = widget.episodeGroups[_groupIndex];
    _trackDialog(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(_sourceName, style: const TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 460,
            height: episodes.length > 8 ? 480 : null,
            child: ListView.builder(
              shrinkWrap: episodes.length <= 8,
              itemCount: episodes.length,
              itemBuilder: (_, i) {
                final selected = i == _episodeIndex;
                return _PickerTile(
                  title: episodes[i].name,
                  selected: selected,
                  autofocus: selected,
                  onTap: () {
                    Navigator.of(context).pop();
                    if (i != _episodeIndex) _switchEpisode(_groupIndex, i);
                  },
                );
              },
            ),
          ),
        ),
      ),
      onComplete: () {
        if (mounted) _scheduleHide();
      },
    );
  }

  void _showTvSourcePicker() {
    _trackDialog(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('切换线路', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 420,
            height: widget.episodeGroups.length > 8 ? 440 : null,
            child: ListView.builder(
              shrinkWrap: widget.episodeGroups.length <= 8,
              itemCount: widget.episodeGroups.length,
              itemBuilder: (_, i) {
                final selected = i == _groupIndex;
                final name = widget.sourceNames.length > i
                    ? widget.sourceNames[i]
                    : '线路 ${i + 1}';
                return _PickerTile(
                  title: name,
                  selected: selected,
                  autofocus: selected,
                  onTap: () {
                    Navigator.of(context).pop();
                    if (i != _groupIndex) {
                      _switchEpisode(
                        i,
                        _episodeIndex.clamp(
                          0,
                          widget.episodeGroups[i].length - 1,
                        ),
                      );
                    }
                  },
                );
              },
            ),
          ),
        ),
      ),
      onComplete: () {
        if (mounted) _scheduleHide();
      },
    );
  }

  void _showTvQualityPicker() {
    _trackDialog(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('画质', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PickerTile(
                title: '自动',
                selected: _currentQuality.isAuto,
                autofocus: _currentQuality.isAuto,
                onTap: () {
                  Navigator.of(context).pop();
                  _selectQuality(const VideoQuality.auto());
                },
              ),
              ..._qualities.map((q) {
                final selected = q.id == _currentQuality.id;
                return _PickerTile(
                  title: _qualityLabel(q),
                  subtitle: '${q.width}×${q.height}',
                  selected: selected,
                  autofocus: selected,
                  onTap: () {
                    Navigator.of(context).pop();
                    _selectQuality(q);
                  },
                );
              }),
            ],
          ),
        ),
      ),
      onComplete: () {
        if (mounted) _scheduleHide();
      },
    );
  }

  void _showTvSpeedPicker() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    _trackDialog(
      showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('倍速', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: speeds.map((s) {
              final selected = s == _playbackSpeed;
              return _PickerTile(
                title: _speedLabel(s),
                selected: selected,
                autofocus: selected,
                onTap: () {
                  Navigator.of(context).pop();
                  setState(() => _playbackSpeed = s);
                  _engine.setRate(s);
                },
              );
            }).toList(),
          ),
        ),
      ),
      onComplete: () {
        if (mounted) _scheduleHide();
      },
    );
  }

  static String _qualityLabel(VideoQuality q) {
    final h = q.height ?? 0;
    if (h >= 2160) return '4K';
    if (h >= 1080) return '1080P';
    if (h >= 720) return '720P';
    if (h >= 480) return '480P';
    if (h >= 360) return '360P';
    return '${h}P';
  }

  static String _speedLabel(double s) {
    if (s == s.truncateToDouble()) return '${s.toInt()}x';
    return '${s}x';
  }

  // ── 历史记录 ──

  void _saveHistory() {
    if (_duration == Duration.zero) return;
    _historyStorage.save(
      WatchHistory(
        videoId: widget.videoId,
        siteKey: widget.site.key,
        title: widget.videoTitle,
        cover: widget.cover,
        episodeName: _current.name,
        episodeIndex: _episodeIndex,
        groupIndex: _groupIndex,
        positionMs: _position.inMilliseconds,
        durationMs: _duration.inMilliseconds,
        updatedAt: DateTime.now(),
        category: widget.category,
      ),
    );
  }

  // ── 键盘 / 遥控器事件 ──

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (PlatformService.isTv) return _handleTvKey(event);

    // 松开方向键时停止加速（只影响外层自己启动的 hold）
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _stopSeekHold();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // 仅处理 KeyDownEvent；KeyRepeatEvent 由 _seekHoldTimer 自主控制频率
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (_isPlayPauseKey(event.logicalKey)) {
      _showControls();
      _engine.playOrPause();
      return KeyEventResult.handled;
    }

    // 全局快捷键：无论控制栏是否可见、焦点在哪里，都处理
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _stopSeekHold();
        // 全屏中按 ESC：先退出全屏，不返回上一页
        if (_isFullscreen) {
          _toggleFullscreen();
        } else {
          context.pop();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.goBack:
        _stopSeekHold();
        // TV：有控制栏时先隐藏，再按才退出；更符合遥控器使用习惯
        if (PlatformService.isTv && _controlsVisible) {
          _hideControls();
        } else {
          context.pop();
        }
        return KeyEventResult.handled;
    }

    // 非 TV（桌面键盘 / 手机外接键盘）：保留全局播放快捷键，同时允许桌面模拟 TV 面板
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _startSeekHold(false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _startSeekHold(true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.contextMenu:
        _showControls();
        _showPlaybackOptionsPanel();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (_usesLeanbackControls) {
          if (_controlsVisible) {
            _hideControls();
          } else {
            _showControls();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.keyM:
        _showControls();
        _showPlaybackOptionsPanel();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  KeyEventResult _handleTvKey(KeyEvent event) {
    final key = event.logicalKey;

    if (_error != null) {
      _stopSeekHold();
      if (event is KeyDownEvent &&
          (key == LogicalKeyboardKey.goBack ||
              key == LogicalKeyboardKey.escape)) {
        context.pop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        _stopSeekHold();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          _isPlayPauseKey(key)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (_isPlayPauseKey(key)) {
      _engine.playOrPause();
      _showControls();
      return KeyEventResult.handled;
    }

    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        _startSeekHold(false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _startSeekHold(true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.contextMenu:
        _showControls();
        _showPlaybackOptionsPanel();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (_controlsVisible) {
          _hideControls();
        } else {
          _showControls();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.goBack:
        _stopSeekHold();
        if (_controlsVisible) {
          _hideControls();
        } else {
          context.pop();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackPrevious:
        if (_hasPrev) _switchEpisode(_groupIndex, _episodeIndex - 1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackNext:
        if (_hasNext) _switchEpisode(_groupIndex, _episodeIndex + 1);
        return KeyEventResult.handled;
      default:
        _showControls();
        return KeyEventResult.handled;
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: Listener(
          // 鼠标滚轮调节音量
          onPointerSignal: _onPointerSignal,
          child: MouseRegion(
            // 桌面：鼠标移入/移动显示控制栏，移出快速隐藏
            // TV：MouseRegion 无鼠标事件，键盘逻辑不受影响
            onEnter: (_) => _showControls(),
            onHover: (_) => _showControls(),
            onExit: _onMouseExit,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onSecondaryTapUp: _isDesktopPlatform ? _showContextMenu : null,
              child: Stack(
                // 加载层移除后只剩 SizedBox.shrink；必须固定为可用区域，
                // 否则 Stack 会缩成 0×0，连同视频与控制栏一起消失。
                fit: StackFit.expand,
                children: [
                  // 全屏视频（禁用内置控件，使用自定义控制栏）
                  Positioned.fill(child: _engine.buildVideoView()),

                  // 加载状态局部刷新，网速/计时不会再重建视频视图和整页控件。
                  ValueListenableBuilder<_LoadingUiState>(
                    valueListenable: _loadingState,
                    builder: (context, loading, _) {
                      if (loading.isInitialLoading) {
                        return _LoadingOverlay(
                          title: widget.videoTitle,
                          episodeName: _current.name,
                          sourceName: '${widget.site.name} · $_sourceName',
                          bufferingSeconds: loading.waitingSeconds,
                          speedBps: loading.appRxBytesPerSecond,
                        );
                      }
                      if (loading.isRebuffering) {
                        return _RebufferIndicator(
                          bufferingSeconds: loading.waitingSeconds,
                          speedBps: loading.appRxBytesPerSecond,
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),

                  // 播放失败遮罩
                  if (_error != null)
                    _ErrorOverlay(
                      message: _error!,
                      sourceName: _sourceName,
                      onRetry: () {
                        setState(() => _error = null);
                        _playCurrentEpisode();
                      },
                      onBack: () => context.pop(),
                      // 多线路时提供手动切换
                      onSwitchSource: widget.episodeGroups.length > 1
                          ? () {
                              final next =
                                  (_groupIndex + 1) %
                                  widget.episodeGroups.length;
                              final epIdx = _episodeIndex.clamp(
                                0,
                                widget.episodeGroups[next].length - 1,
                              );
                              setState(() {
                                _groupIndex = next;
                                _episodeIndex = epIdx;
                                _error = null;
                              });
                              _playCurrentEpisode();
                            }
                          : null,
                    ),

                  // 返回按钮（左上角）
                  Positioned(
                    top: 0,
                    left: 0,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_controlsVisible,
                        child: ExcludeFocus(
                          excluding: !_controlsVisible,
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              child: _FocusableRow(
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(24),
                                ),
                                onActivate: () => context.pop(),
                                child: const Icon(
                                  Icons.arrow_back,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 控制栏（底部）：Positioned 必须是 Stack 直接子级
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_controlsVisible,
                        // ExcludeFocus：控制栏隐藏时剥夺内部焦点，焦点自然回到外层
                        // _rootFocusNode，TV 用户下一次按键会先拉起控制栏
                        child: ExcludeFocus(
                          excluding: !_controlsVisible,
                          // 包一层空 onTap 吃掉控制栏区域的 tap，防止冒泡到外层
                          // _toggleControls —— 点击控制栏空隙不该隐藏控制栏；同时
                          // 避免手机端外层 Tap 手势抢占 Slider 的 tap-to-seek。
                          // 子组件（按钮、Slider）的手势识别器仍优先胜出（deepest wins）。
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              // 点击控制栏时重置自动隐藏计时器，保持可见
                              _showControls();
                            },
                            child: _buildControlBar(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControlBar() {
    if (_usesLeanbackControls) return _buildLeanbackControlBar();

    final isMobile = PlatformService.isMobile;
    final hPad = isMobile ? AppSpacing.md : AppSpacing.xl;
    final btnGap = isMobile ? AppSpacing.lg : AppSpacing.xl;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      padding: EdgeInsets.fromLTRB(hPad, AppSpacing.lg, hPad, AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行：倍速 / 音量 / 画质 / 线路 / 全屏 全部归拢到这里
          Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.videoTitle}  ${_current.name} · ${widget.site.name}',
                  style: AppTypography.caption,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 倍速选择器（始终显示）
              _SpeedSelector(
                currentSpeed: _playbackSpeed,
                onSelect: (s) {
                  setState(() => _playbackSpeed = s);
                  _engine.setRate(s);
                  _showControls();
                },
              ),
              const SizedBox(width: AppSpacing.md),
              // 音量提示（桌面端）
              if (_isDesktopPlatform)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.md),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _volume == 0
                            ? Icons.volume_off
                            : _volume < 0.5
                            ? Icons.volume_down
                            : Icons.volume_up,
                        color: Colors.white70,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${(_volume * 100).round()}%',
                        style: AppTypography.caption,
                      ),
                    ],
                  ),
                ),
              // 画质切换（HLS 多码率时显示）
              if (_qualities.length > 1) ...[
                _QualitySelector(
                  qualities: _qualities,
                  currentQuality: _currentQuality,
                  onSelect: (q) {
                    _selectQuality(q);
                  },
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              // 多线路时显示可切换的线路选择器
              if (widget.episodeGroups.length > 1)
                _SourceSelector(
                  sourceNames: widget.sourceNames,
                  currentIndex: _groupIndex,
                  onSelect: (i) => _switchEpisode(i, 0),
                )
              else
                Text(_sourceName, style: AppTypography.caption),
              // 全屏按钮：桌面 + 移动（TV 始终全屏无需切换）
              if (!PlatformService.isTv &&
                  (_isDesktopPlatform || PlatformService.isMobile)) ...[
                const SizedBox(width: AppSpacing.md),
                _FocusableRow(
                  onActivate: _toggleFullscreen,
                  child: Icon(
                    _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    color: Colors.white70,
                    size: 18,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),

          // 高频 position/buffer 更新只重建这一行。
          ValueListenableBuilder<PlaybackProgressState>(
            valueListenable: _progressState,
            builder: (context, progress, _) => Row(
              children: [
                Text(_fmt(progress.position), style: AppTypography.caption),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: ExcludeFocus(
                    excluding: PlatformService.isTv,
                    child: _buildSlider(progress),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _BufferAheadLabel(progress: progress, compact: isMobile),
                const SizedBox(width: AppSpacing.sm),
                Text(_fmt(progress.duration), style: AppTypography.caption),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),

          // 按钮行
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Btn(
                icon: Icons.skip_previous,
                onTap: _hasPrev
                    ? () => _switchEpisode(_groupIndex, _episodeIndex - 1)
                    : null,
              ),
              SizedBox(width: btnGap),
              _HoldBtn(
                icon: Icons.replay_10,
                onHoldStart: () => _startSeekHold(false),
                onHoldEnd: _stopSeekHold,
              ),
              SizedBox(width: btnGap),
              _Btn(
                icon: _playing ? Icons.pause : Icons.play_arrow,
                size: 48,
                focusNode: _playPauseFocusNode,
                onTap: () {
                  _engine.playOrPause();
                  _showControls();
                },
              ),
              SizedBox(width: btnGap),
              _HoldBtn(
                icon: Icons.forward_10,
                onHoldStart: () => _startSeekHold(true),
                onHoldEnd: _stopSeekHold,
              ),
              SizedBox(width: btnGap),
              _Btn(
                icon: Icons.skip_next,
                onTap: _hasNext
                    ? () => _switchEpisode(_groupIndex, _episodeIndex + 1)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLeanbackControlBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xB3000000), Color(0xF5000000)],
          stops: [0.0, 0.42, 1.0],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(72, 56, 72, 34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.videoTitle,
                      style: AppTypography.title.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${_current.name} · ${widget.site.name} · $_sourceName${_currentQuality.isAuto ? '' : ' · ${_qualityLabel(_currentQuality)}'}',
                      style: AppTypography.body.copyWith(
                        color: Colors.white60,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (_qualities.length > 1) ...[
                const SizedBox(width: AppSpacing.md),
                _LeanbackActionButton(
                  icon: Icons.hd,
                  label: _currentQuality.isAuto
                      ? '自动'
                      : _qualityLabel(_currentQuality),
                  dense: true,
                  onTap: _showTvQualityPicker,
                ),
              ],
              const SizedBox(width: AppSpacing.sm),
              _LeanbackActionButton(
                icon: Icons.speed,
                label: _speedLabel(_playbackSpeed),
                dense: true,
                onTap: _showTvSpeedPicker,
              ),
              const SizedBox(width: AppSpacing.sm),
              _LeanbackActionButton(
                icon: Icons.swap_horiz,
                label: _sourceName,
                dense: true,
                onTap: widget.episodeGroups.length > 1
                    ? _showTvSourcePicker
                    : null,
              ),
              const SizedBox(width: AppSpacing.sm),
              _LeanbackActionButton(
                icon: Icons.video_library,
                label: '选集',
                dense: true,
                onTap: _showTvEpisodePicker,
              ),
              const SizedBox(width: AppSpacing.sm),
              _LeanbackActionButton(
                icon: Icons.tune,
                label: '更多',
                dense: true,
                onTap: _showPlaybackOptionsPanel,
              ),
              if (_isDesktopPlatform || PlatformService.isMobile) ...[
                const SizedBox(width: AppSpacing.sm),
                _LeanbackActionButton(
                  icon: _isFullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  label: _isFullscreen ? '退出' : '全屏',
                  dense: true,
                  onTap: _toggleFullscreen,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ValueListenableBuilder<PlaybackProgressState>(
            valueListenable: _progressState,
            builder: (context, progress, _) => Row(
              children: [
                SizedBox(
                  width: 70,
                  child: Text(
                    _fmt(progress.position),
                    style: AppTypography.body.copyWith(color: Colors.white70),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _isDesktopPlatform
                      ? _buildSlider(progress)
                      : _buildTvProgressBar(progress),
                ),
                const SizedBox(width: AppSpacing.md),
                _BufferAheadLabel(progress: progress),
                const SizedBox(width: AppSpacing.md),
                SizedBox(
                  width: 88,
                  child: Text(
                    _fmt(progress.duration),
                    textAlign: TextAlign.right,
                    style: AppTypography.body.copyWith(color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _LeanbackActionButton(
                icon: Icons.skip_previous,
                label: '上一集',
                onTap: _hasPrev
                    ? () => _switchEpisode(_groupIndex, _episodeIndex - 1)
                    : null,
              ),
              const SizedBox(width: AppSpacing.md),
              _LeanbackActionButton(
                icon: Icons.replay_10,
                label: '后退',
                onTap: () => _seekRelative(const Duration(seconds: -10)),
              ),
              const SizedBox(width: AppSpacing.lg),
              _LeanbackPlayButton(
                playing: _playing,
                focusNode: _playPauseFocusNode,
                onTap: () {
                  _engine.playOrPause();
                  _showControls();
                },
              ),
              const SizedBox(width: AppSpacing.lg),
              _LeanbackActionButton(
                icon: Icons.forward_10,
                label: '前进',
                onTap: () => _seekRelative(const Duration(seconds: 10)),
              ),
              const SizedBox(width: AppSpacing.md),
              _LeanbackActionButton(
                icon: Icons.skip_next,
                label: '下一集',
                onTap: _hasNext
                    ? () => _switchEpisode(_groupIndex, _episodeIndex + 1)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTvProgressBar(PlaybackProgressState state) {
    if (!state.hasKnownDuration) {
      return const ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        child: LinearProgressIndicator(
          minHeight: 8,
          backgroundColor: Color(0xFF343434),
          color: Colors.white30,
        ),
      );
    }
    final animationDuration = _seeking
        ? Duration.zero
        : const Duration(milliseconds: 250);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: state.bufferedRatio),
      duration: animationDuration,
      curve: Curves.linear,
      builder: (context, animatedBuffered, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: state.progressRatio),
        duration: animationDuration,
        curve: Curves.linear,
        builder: (context, animatedProgress, _) => SizedBox(
          height: 8,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: const Color(0xFF343434)),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: animatedBuffered.clamp(0.0, 1.0),
                  child: Container(color: Colors.white24),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: animatedProgress.clamp(0.0, 1.0),
                  child: Container(color: AppColors.netflixRed),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSlider(PlaybackProgressState state) {
    if (!state.hasKnownDuration) {
      return const ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(2)),
        child: LinearProgressIndicator(
          minHeight: 4,
          backgroundColor: Color(0xFF3A3A3A),
          color: Colors.white30,
        ),
      );
    }
    final sliderTheme = SliderThemeData(
      trackHeight: 4,
      activeTrackColor: AppColors.netflixRed,
      // 未缓冲区域：偏暗灰，让缓冲指示条能从中"突出"
      inactiveTrackColor: const Color(0xFF3A3A3A),
      // 缓冲指示条：半透明白，位于 active 和 inactive 之间
      secondaryActiveTrackColor: Colors.white30,
      thumbColor: AppColors.netflixRed,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: SliderComponentShape.noOverlay,
    );

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: state.bufferedRatio),
      duration: _seeking ? Duration.zero : const Duration(milliseconds: 250),
      curve: Curves.linear,
      builder: (context, animatedBuffered, _) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: state.progressRatio),
        duration: _seeking ? Duration.zero : const Duration(milliseconds: 200),
        curve: Curves.linear,
        builder: (context, animatedProgress, _) {
          final currentValue = animatedProgress.clamp(0.0, 1.0);
          final secondary = animatedBuffered < currentValue
              ? currentValue
              : animatedBuffered.clamp(0.0, 1.0);
          return SliderTheme(
            data: sliderTheme,
            child: Slider(
              value: currentValue,
              secondaryTrackValue: secondary,
              onChangeStart: (_) {
                _hideTimer?.cancel();
                setState(() => _seeking = true);
              },
              onChanged: (value) {
                _position = Duration(
                  milliseconds: (value * state.duration.inMilliseconds).round(),
                );
                _publishProgressState();
              },
              onChangeEnd: (value) {
                final target = Duration(
                  milliseconds: (value * state.duration.inMilliseconds).round(),
                );
                setState(() => _seeking = false);
                _seekTo(target);
                _scheduleHide();
              },
            ),
          );
        },
      ),
    );
  }

  /// 当前正在缓冲的秒数（已开始播放但 re-buffer、或首次加载）。
  /// `_buffStartAt` 为 null 时返回 0。
  int _bufferingSeconds() {
    final start = _buffStartAt;
    if (start == null) return 0;
    return DateTime.now().difference(start).inSeconds;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
          '${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

// ── 子组件 ──
