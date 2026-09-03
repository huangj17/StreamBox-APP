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
part 'player_controls.dart';
part 'player_panels.dart';

bool _isConfirmKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.gameButtonA;

bool _isBackKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.goBack ||
    key == LogicalKeyboardKey.browserBack ||
    key == LogicalKeyboardKey.gameButtonB;

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
  late final Widget _videoSurface;
  late HistoryStorage _historyStorage;
  late PlayerSettingsStorage _playerSettings;

  late int _groupIndex;
  late int _episodeIndex;

  bool _controlsVisible = true;
  bool _isFullscreen = false;
  Timer? _hideTimer;

  final _rootFocusNode = FocusNode(debugLabel: 'playerRoot');
  final _progressFocusNode = FocusNode(debugLabel: 'playerProgress');
  final _backFocusNode = FocusNode(debugLabel: 'playerBack');
  final Map<String, FocusNode> _actionNodes = {};
  final Map<String, FocusNode> _errorNodes = {};
  String _lastAction = 'playPause';
  Duration? _seekPreview;
  LogicalKeyboardKey? _seekKey;
  int _seekRepeatCount = 0;
  _PlayerPanel? _panel;
  _PlayerPanel? _panelParent;
  FocusNode? _panelOrigin;
  bool _allowExit = false;
  int _settingsPanelIndex = 0;

  void _update(VoidCallback update) => setState(update);

  FocusNode _actionNode(String id) =>
      _actionNodes.putIfAbsent(id, () => FocusNode(debugLabel: 'player:$id'));
  FocusNode _errorNode(String id) => _errorNodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'playerError:$id'),
  );

  List<String> get _actionIds => [
    'playPause',
    if (_hasPrev) 'previous',
    if (_hasNext) 'next',
    if (widget.episodeGroups[_groupIndex].length > 1) 'episodes',
    if (widget.episodeGroups.where((group) => group.isNotEmpty).length > 1)
      'sources',
    'settings',
    if (!PlatformService.isTv) 'fullscreen',
  ];

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
    _videoSurface = RepaintBoundary(child: _engine.buildVideoView());

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
      if (p) {
        _scheduleHide();
      } else {
        _showControls();
      }
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
        var nextGroup = _groupIndex + 1;
        while (nextGroup < widget.episodeGroups.length &&
            widget.episodeGroups[nextGroup].isEmpty) {
          nextGroup++;
        }
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
          _setError(errorMsg);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _error == null) _actionNode('playPause').requestFocus();
    });

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
    _progressFocusNode.dispose();
    _backFocusNode.dispose();
    for (final node in [..._actionNodes.values, ..._errorNodes.values]) {
      node.dispose();
    }
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
      _hideTimer?.cancel();
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
    if (!value) _scheduleHide();
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
    if (_error != null && mounted) {
      setState(() => _error = null);
      _restoreControlsFocus();
    }
    _scheduleHide();
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
        _setError(_stuckMessage);
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
    _seekPreview = null;
    _seekKey = null;
    _seeking = false;
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
      _setError('播放地址解析失败：$error');
    }
  }

  void _logBufferMetrics() {
    if (!kDebugMode || !_bufferMetrics.hasSession) return;
    debugPrint('播放缓存指标: ${_bufferMetrics.snapshot(DateTime.now())}');
  }

  void _switchEpisode(int groupIndex, int episodeIndex) {
    _saveHistory();
    _resumePositionMs = 0;
    setState(() {
      _groupIndex = groupIndex;
      _episodeIndex = episodeIndex;
    });
    _playCurrentEpisode();
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
      _setError('切换画质失败：$error');
    }
  }

  // ── 控件、进度预览与面板 ──

  void _restoreControlsFocus([FocusNode? node]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _panel != null) return;
      if (_error != null) {
        _errorNode('retry').requestFocus();
      } else if (_controlsVisible) {
        final target = node;
        if (target != null &&
            target.context != null &&
            target.canRequestFocus) {
          target.requestFocus();
        } else {
          _actionNode('playPause').requestFocus();
        }
      }
    });
  }

  void _setError(String message) {
    _hideTimer?.cancel();
    setState(() {
      _error = message;
      _seekPreview = null;
      _seekKey = null;
      _seeking = false;
      _controlsVisible = true;
    });
    _restoreControlsFocus();
  }

  void _showControls({bool focus = false}) {
    final wasHidden = !_controlsVisible;
    if (wasHidden) setState(() => _controlsVisible = true);
    if (wasHidden || focus) _restoreControlsFocus();
    _scheduleHide();
  }

  void _toggleControls() {
    if (_panel != null || _error != null || _seekPreview != null) return;
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  void _hideControls() {
    if (_panel != null || _seekPreview != null || _error != null) return;
    _hideTimer?.cancel();
    if (_controlsVisible) setState(() => _controlsVisible = false);
    _rootFocusNode.requestFocus();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_playing ||
        _buffering ||
        _progressEvidence.isArmed ||
        _panel != null ||
        _seekPreview != null ||
        _error != null) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) _hideControls();
    });
  }

  void _onMouseExit(PointerExitEvent _) => _scheduleHide();

  void _onPointerSignal(PointerSignalEvent event) {
    if (_panel != null) return;
    if (event is PointerScrollEvent) {
      final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
      setState(() => _volume = (_volume + delta).clamp(0.0, 1.0));
      _engine.setVolume(_volume);
      _showControls();
    }
  }

  void _previewSeek(bool forward, {bool repeat = false}) {
    if (_duration <= Duration.zero) return;
    final key = forward
        ? LogicalKeyboardKey.arrowRight
        : LogicalKeyboardKey.arrowLeft;
    // 取消预览后忽略仍然按住的方向键重复事件，直到下一次重新按下。
    if (repeat && _seekKey != key) return;
    _seekKey = key;
    if (!repeat) _seekRepeatCount = 0;
    final step = _seekRepeatCount < 8
        ? 10
        : _seekRepeatCount < 20
        ? 30
        : 60;
    _seekRepeatCount++;
    final target =
        ((_seekPreview ?? _position).inMilliseconds +
                (forward ? step : -step) * 1000)
            .clamp(0, _duration.inMilliseconds);
    _hideTimer?.cancel();
    setState(() {
      _controlsVisible = true;
      _seekPreview = Duration(milliseconds: target);
    });
    _restoreControlsFocus(_progressFocusNode);
  }

  void _finishSeek({required bool commit}) {
    final target = _seekPreview;
    setState(() {
      _seekPreview = null;
      _seekKey = null;
      _seekRepeatCount = 0;
      _seeking = false;
    });
    if (commit && target != null) {
      _position = target;
      _publishProgressState();
      _seekTo(target);
    }
    _scheduleHide();
  }

  void _openPanel(_PlayerPanel panel) {
    if (_seekPreview != null) _finishSeek(commit: false);
    _hideTimer?.cancel();
    if (_panel == null) _panelOrigin = FocusManager.instance.primaryFocus;
    setState(() {
      _panelParent = _panel == _PlayerPanel.settings ? _panel : null;
      _panel = panel;
      _controlsVisible = true;
    });
  }

  void _closePanel() {
    setState(() {
      _panel = _panelParent;
      _panelParent = null;
    });
    if (_panel == null) {
      _restoreControlsFocus(_panelOrigin);
      _scheduleHide();
    }
  }

  void _exitPlayer() {
    _hideTimer?.cancel();
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.canPop()) context.pop();
    });
  }

  void _handleBack() {
    if (_panel != null) {
      _closePanel();
    } else if (_seekPreview != null) {
      _finishSeek(commit: false);
    } else if (_error != null) {
      _exitPlayer();
    } else if (_controlsVisible) {
      _hideControls();
    } else if (_isFullscreen && !PlatformService.isTv) {
      _toggleFullscreen();
    } else {
      _exitPlayer();
    }
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
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == _seekKey) {
        _finishSeek(commit: _panel == null && _error == null);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_isBackKey(key)) {
      if (event is KeyDownEvent) _handleBack();
      return KeyEventResult.handled;
    }
    // 面板内部拥有自己的方向键与确认键；父级不得触发播放快捷键。
    if (_panel != null) return KeyEventResult.ignored;
    if (_error != null) {
      final ids = [
        'retry',
        if (_actionIds.contains('sources')) 'sources',
        'back',
      ];
      final current = ids.indexWhere((id) => _errorNode(id).hasFocus);
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowUp) {
        _errorNode(ids[(current - 1).clamp(0, ids.length - 1)]).requestFocus();
      } else if (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.arrowDown) {
        _errorNode(ids[(current + 1).clamp(0, ids.length - 1)]).requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) {
        _engine.playOrPause();
        _showControls();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent) {
        if (key == LogicalKeyboardKey.mediaTrackNext && _hasNext) {
          _switchEpisode(_groupIndex, _episodeIndex + 1);
        }
        if (key == LogicalKeyboardKey.mediaTrackPrevious && _hasPrev) {
          _switchEpisode(_groupIndex, _episodeIndex - 1);
        }
        _restoreControlsFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) _openPanel(_PlayerPanel.settings);
      return KeyEventResult.handled;
    }
    final horizontal =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    final vertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (!_controlsVisible) {
      if (horizontal) {
        _previewSeek(
          key == LogicalKeyboardKey.arrowRight,
          repeat: event is KeyRepeatEvent,
        );
      } else if (vertical || _isConfirmKey(key)) {
        _showControls(focus: true);
      }
      return horizontal || vertical || _isConfirmKey(key)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (_progressFocusNode.hasFocus) {
      if (horizontal) {
        _previewSeek(
          key == LogicalKeyboardKey.arrowRight,
          repeat: event is KeyRepeatEvent,
        );
      } else if (_isConfirmKey(key)) {
        if (event is KeyDownEvent && _seekPreview == null) {
          _actionNode(
            _actionIds.contains(_lastAction) ? _lastAction : 'playPause',
          ).requestFocus();
        }
      } else if (vertical) {
        // 离开时间轴取消预览，避免随后松开方向键时误跳转。
        if (_seekPreview != null) _finishSeek(commit: false);
        if (key == LogicalKeyboardKey.arrowUp) {
          _backFocusNode.requestFocus();
        } else {
          _actionNode(
            _actionIds.contains(_lastAction) ? _lastAction : 'playPause',
          ).requestFocus();
        }
      }
    } else if (_backFocusNode.hasFocus) {
      if (vertical) _progressFocusNode.requestFocus();
    } else {
      final ids = _actionIds;
      final index = ids.indexWhere((id) => _actionNode(id).hasFocus);
      if (horizontal) {
        final next = (index + (key == LogicalKeyboardKey.arrowRight ? 1 : -1))
            .clamp(0, ids.length - 1);
        _actionNode(ids[next]).requestFocus();
      } else if (key == LogicalKeyboardKey.arrowUp) {
        _progressFocusNode.requestFocus();
      } else if (_isConfirmKey(key) && event is KeyDownEvent) {
        _actionNode('playPause').requestFocus();
      }
    }
    _scheduleHide();
    return horizontal || vertical || _isConfirmKey(key)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final showControls = _controlsVisible && _error == null && _panel == null;
    return PopScope(
      canPop:
          _allowExit ||
          (_panel == null &&
              _seekPreview == null &&
              !_controlsVisible &&
              !_isFullscreen),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocusNode,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: MouseRegion(
              onEnter: (_) => _showControls(),
              onHover: (_) => _showControls(),
              onExit: _onMouseExit,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onSecondaryTapUp: _isDesktopPlatform
                    ? (_) => _openPanel(_PlayerPanel.settings)
                    : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(child: _videoSurface),
                    IgnorePointer(
                      child: ValueListenableBuilder<_LoadingUiState>(
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
                    ),
                    ExcludeFocus(
                      excluding: !showControls,
                      child: IgnorePointer(
                        ignoring: !showControls,
                        child: AnimatedOpacity(
                          opacity: showControls ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Stack(
                            children: [
                              Positioned(
                                top: 0,
                                left: 0,
                                child: SafeArea(
                                  child: Padding(
                                    padding: EdgeInsets.all(
                                      MediaQuery.sizeOf(context).width >= 1000
                                          ? 40
                                          : 16,
                                    ),
                                    child: _PlayerButton(
                                      focusNode: _backFocusNode,
                                      icon: Icons.arrow_back,
                                      label: '退出播放',
                                      onTap: _exitPlayer,
                                      onFocused: _scheduleHide,
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _scheduleHide,
                                  child: _buildControlBar(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_error != null)
                      ExcludeFocus(
                        excluding: _panel != null,
                        child: _buildError(),
                      ),
                    if (_panel != null) _buildPanel(),
                  ],
                ),
              ),
            ),
          ),
        ),
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
