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
import '../../data/models/episode.dart';
import '../../data/models/watch_history.dart';
import '../../data/local/history_storage.dart';
import '../../data/local/player_settings_storage.dart';
import '../home/providers/categories_provider.dart';
import 'engine/video_engine.dart';
import 'engine/video_engine_factory.dart';

/// 全屏播放页
class PlayerScreen extends ConsumerStatefulWidget {
  final String videoId;
  final String siteKey;
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
    required this.siteKey,
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

class _PlayerScreenState extends ConsumerState<PlayerScreen> with WindowListener {
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

  // ── 计算属性 ──

  Episode get _current =>
      widget.episodeGroups[_groupIndex][_episodeIndex];

  bool get _hasPrev => _episodeIndex > 0;
  bool get _hasNext =>
      _episodeIndex < widget.episodeGroups[_groupIndex].length - 1;

  String get _sourceName => widget.sourceNames.length > _groupIndex
      ? widget.sourceNames[_groupIndex]
      : '线路 ${_groupIndex + 1}';

  double get _progress => _duration.inMilliseconds > 0
      ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
      : 0.0;

  // ── 生命周期 ──

  @override
  void initState() {
    super.initState();
    _groupIndex = widget.initialGroupIndex;
    _episodeIndex = widget.initialEpisodeIndex;
    _historyStorage = ref.read(historyStorageProvider);
    _playerSettings = ref.read(playerSettingsStorageProvider);

    _engine = createVideoEngine(
      hardwareDecode: _playerSettings.hardwareDecode,
    );

    // 应用默认倍速
    _playbackSpeed = _playerSettings.defaultSpeed;
    if (_playbackSpeed != 1.0) {
      _engine.setRate(_playbackSpeed);
    }

    _resumePositionMs = widget.initialPositionMs;

    _posSub = _engine.positionStream.listen((p) {
      if (!_seeking && mounted) setState(() => _position = p);
    });
    _durSub = _engine.durationStream.listen((d) {
      if (mounted) {
        setState(() {
          _duration = d;
          // duration 有效说明视频加载成功，清除瞬态错误
          if (d.inMilliseconds > 0 && _error != null) {
            _error = null;
            _errorTimer?.cancel();
          }
        });
        // 续播定位：首次 duration 确定后 seek 到历史位置
        if (_resumePositionMs > 0 && d.inMilliseconds > 0) {
          _engine.seek(Duration(milliseconds: _resumePositionMs));
          _resumePositionMs = 0;
        }
      }
    });
    _bufSub = _engine.bufferingStream.listen((b) {
      if (!mounted) return;
      setState(() {
        _buffering = b;
        // 进入缓冲时记录开始时间；退出时清除
        if (b) {
          _buffStartAt ??= DateTime.now();
        } else {
          _buffStartAt = null;
        }
      });
    });
    _bufferedSub = _engine.bufferedStream.listen((b) {
      if (mounted) setState(() => _buffered = b);
    });
    _playSub = _engine.playingStream.listen((p) {
      if (!mounted) return;
      setState(() {
        _playing = p;
        // 开始播放说明视频正常，清除瞬态错误
        if (p && _error != null) {
          _error = null;
          _errorTimer?.cancel();
        }
      });
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('当前源支持多画质切换（最高 $label）'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          backgroundColor: const Color(0xDD333333),
          margin: const EdgeInsets.only(bottom: 80, left: 20, right: 20),
        ));
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
      // 延迟显示错误：给 libmpv 1.5s 缓冲，如果这段时间内
      // playing/duration 变为有效值，错误会被清除而不会显示
      final errorMsg = err.isNotEmpty ? err : '播放失败';
      _errorTimer?.cancel();
      _errorTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted && !_playing && _duration == Duration.zero) {
          setState(() => _error = errorMsg);
        }
      });
    });

    // 网速监视（Android / iOS 走 native，桌面 native 方法不存在时自动返回 null）
    _speedSub = _speedMonitor.stream.listen((bps) {
      if (mounted) setState(() => _speedBps = bps);
    });
    _speedMonitor.start();

    // 缓冲计时刷新（每秒触发一次 setState 用于刷新"已加载 Ns"文字）
    _buffTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _buffStartAt != null) setState(() {});
    });

    _buffStartAt = DateTime.now();
    _playCurrentEpisode();
    _scheduleHide();

    // 播放期间保持屏幕常亮：酷开等 Android TV ROM 屏保触发后会杀掉前台 App
    WakelockPlus.enable();

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
    WakelockPlus.disable();
    _hideTimer?.cancel();
    _seekHoldTimer?.cancel();
    _errorTimer?.cancel();
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

  void _playCurrentEpisode() {
    final url = _current.url;
    if (url.isEmpty) return;
    _errorTimer?.cancel();
    setState(() {
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffered = Duration.zero;
      _buffering = true;
      _error = null;
      _qualities = [];
      _currentQuality = const VideoQuality.auto();
      _buffStartAt = DateTime.now();
    });
    _engine.open(url);
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
    final ms = (_position + delta)
        .inMilliseconds
        .clamp(0, _duration.inMilliseconds);
    _engine.seek(Duration(milliseconds: ms));
    _showControls();
  }

  // ── 快进/快退长按加速 ──

  /// 按住时每次 seek 的秒数：按得越久档位越高
  /// 间隔 150ms，档位：0~3次 10s → 4~12次 30s → 13次+ 60s
  int _seekSeconds() {
    if (_seekHoldCount < 4)  return 10;  // 0~0.45s : ±10s
    if (_seekHoldCount < 13) return 30;  // 0.6~1.8s: ±30s
    return 60;                           // 1.95s+  : ±60s
  }

  /// 按下时调用：立即 seek 一次，然后以 150ms 间隔持续加速 seek
  void _startSeekHold(bool forward) {
    _stopSeekHold();
    _seekHoldCount = 0;

    void doSeek() {
      _seekRelative(Duration(seconds: forward ? _seekSeconds() : -_seekSeconds()));
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
        position.dx, position.dy, position.dx, position.dy,
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
                const Icon(Icons.speed, color: AppColors.secondaryText, size: 18),
                const SizedBox(width: 8),
                Text('倍速 ${_playbackSpeed}x',
                    style: const TextStyle(color: AppColors.primaryText)),
              ],
            ),
            itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                .map((s) => PopupMenuItem(
                      value: s,
                      child: Text(
                        '${s}x',
                        style: TextStyle(
                          color: s == _playbackSpeed
                              ? AppColors.netflixRed
                              : AppColors.primaryText,
                        ),
                      ),
                    ))
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
                  Text(name,
                      style: TextStyle(
                        color: i == _groupIndex
                            ? AppColors.netflixRed
                            : AppColors.primaryText,
                      )),
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
          _switchEpisode(idx, _episodeIndex.clamp(
            0, widget.episodeGroups[idx].length - 1,
          ));
        }
      }
    });
  }

  // ── 画质选择对话框（右键菜单触发） ──

  void _showQualityPicker() {
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
                _engine.setQuality(const VideoQuality.auto());
                setState(() => _currentQuality = const VideoQuality.auto());
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
                  _engine.setQuality(q);
                  setState(() => _currentQuality = q);
                },
              );
            }),
          ],
        ),
      ),
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

  // ── 历史记录 ──

  void _saveHistory() {
    if (_duration == Duration.zero) return;
    _historyStorage.save(WatchHistory(
      videoId: widget.videoId,
      siteKey: widget.siteKey,
      title: widget.videoTitle,
      cover: widget.cover,
      episodeName: _current.name,
      episodeIndex: _episodeIndex,
      groupIndex: _groupIndex,
      positionMs: _position.inMilliseconds,
      durationMs: _duration.inMilliseconds,
      updatedAt: DateTime.now(),
      category: widget.category,
    ));
  }

  // ── 键盘 / 遥控器事件 ──

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
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

    // 全局快捷键：无论控制栏是否可见、焦点在哪里，都处理
    switch (event.logicalKey) {
      case LogicalKeyboardKey.mediaPlayPause:
      case LogicalKeyboardKey.space:
        _engine.playOrPause();
        _showControls();
        return KeyEventResult.handled;
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

    // TV 模式：让焦点系统接管方向键 / Select
    // 外层 Focus 只在"控制栏隐藏"时处理按键——任意键先把控制栏拉起并聚焦
    if (PlatformService.isTv) {
      if (!_controlsVisible) {
        _showControls();
        return KeyEventResult.handled;
      }
      // 控制栏已可见时：按键会先命中某个按钮的 Focus；
      // 只有焦点回落到 root 时才会进到这里——重置隐藏计时，让焦点系统自然导航
      _scheduleHide();
      return KeyEventResult.ignored;
    }

    // 非 TV（桌面键盘 / 手机外接键盘）：保留原有全局方向键 seek
    _showControls();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
        _engine.playOrPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _startSeekHold(false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _startSeekHold(true);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
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
            children: [
              // 全屏视频（禁用内置控件，使用自定义控制栏）
              Positioned.fill(child: _engine.buildVideoView()),

              // 初始加载遮罩（还没开始播放时）
              if (_buffering && _position == Duration.zero)
                _LoadingOverlay(
                  title: widget.videoTitle,
                  episodeName: _current.name,
                  sourceName: _sourceName,
                  bufferingSeconds: _bufferingSeconds(),
                  speedBps: _speedBps,
                ),

              // 中途缓冲小圆圈（避开状态栏 / 刘海屏）
              if (_buffering && _position > Duration.zero)
                Positioned(
                  top: 0,
                  right: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: AppSpacing.sm,
                        right: AppSpacing.md,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_speedBps != null)
                            Padding(
                              padding:
                                  const EdgeInsets.only(right: AppSpacing.sm),
                              child: Text(
                                NetworkSpeedMonitor.format(_speedBps),
                                style: AppTypography.caption
                                    .copyWith(color: Colors.white),
                              ),
                            ),
                          const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: AppColors.netflixRed,
                              strokeWidth: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                          final next = (_groupIndex + 1) % widget.episodeGroups.length;
                          final epIdx = _episodeIndex.clamp(0, widget.episodeGroups[next].length - 1);
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
                            borderRadius:
                                const BorderRadius.all(Radius.circular(24)),
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
      padding: EdgeInsets.fromLTRB(
        hPad, AppSpacing.lg, hPad, AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题行：倍速 / 音量 / 画质 / 线路 / 全屏 全部归拢到这里
          Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.videoTitle}  ${_current.name}',
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
                      Text('${(_volume * 100).round()}%',
                          style: AppTypography.caption),
                    ],
                  ),
                ),
              // 画质切换（HLS 多码率时显示）
              if (_qualities.length > 1) ...[
                _QualitySelector(
                  qualities: _qualities,
                  currentQuality: _currentQuality,
                  onSelect: (q) {
                    _engine.setQuality(q);
                    setState(() => _currentQuality = q);
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
              if (_isDesktopPlatform || PlatformService.isMobile) ...[
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

          // 进度条行
          Row(
            children: [
              Text(_fmt(_position), style: AppTypography.caption),
              const SizedBox(width: AppSpacing.sm),
              // TV 遥控器不需要聚焦到 Slider —— 方向键用于按钮间导航，
              // seek 通过专用的快退/快进按钮（长按加速）完成
              Expanded(
                child: ExcludeFocus(
                  excluding: PlatformService.isTv,
                  child: _buildSlider(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(_fmt(_duration), style: AppTypography.caption),
            ],
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

  Widget _buildSlider() {
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

    // 缓冲比例（0~1），duration 未知时为 0
    final bufferedRatio = _duration.inMilliseconds > 0
        ? (_buffered.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return TweenAnimationBuilder<double>(
      // 拖动时 duration=0 立即跟手；播放时 200ms 线性过渡，进度条不抖动
      tween: Tween<double>(end: _progress),
      duration: _seeking ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.linear,
      builder: (context, animValue, _) {
        final currentValue = animValue.clamp(0.0, 1.0);
        // secondary 必须 ≥ value，否则不绘制；取两者较大值
        final secondary = bufferedRatio < currentValue ? currentValue : bufferedRatio;
        return SliderTheme(
          data: sliderTheme,
          child: Slider(
            value: currentValue,
            secondaryTrackValue: secondary,
            onChangeStart: (_) {
              _hideTimer?.cancel();
              setState(() => _seeking = true);
            },
            onChanged: _duration.inMilliseconds > 0
                ? (v) => setState(() {
                      _position = Duration(
                        milliseconds: (v * _duration.inMilliseconds).round(),
                      );
                    })
                : null,
            onChangeEnd: (v) {
              _engine.seek(Duration(
                milliseconds: (v * _duration.inMilliseconds).round(),
              ));
              setState(() => _seeking = false);
              _scheduleHide();
            },
          ),
        );
      },
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

/// 对话框里的可聚焦列表项：选中项红字 + check 图标，焦点态白色半透明底
/// TV 打开对话框时自动聚焦到选中项（通过 autofocus）
class _PickerTile extends StatefulWidget {
  final String title;
  final String? subtitle;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  const _PickerTile({
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.autofocus = false,
  });

  @override
  State<_PickerTile> createState() => _PickerTileState();
}

class _PickerTileState extends State<_PickerTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      descendantsAreFocusable: false,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: _focused
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.transparent,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: widget.selected
                            ? AppColors.netflixRed
                            : Colors.white,
                        fontWeight: widget.selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.selected)
                const Icon(Icons.check, color: AppColors.netflixRed),
            ],
          ),
        ),
      ),
    );
  }
}

/// 通用的可聚焦行/条：用于顶部选择器、全屏按钮、返回按钮等
/// TV 遥控器按 Select/Enter 触发 onActivate
class _FocusableRow extends StatefulWidget {
  final Widget child;
  final VoidCallback onActivate;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  const _FocusableRow({
    required this.child,
    required this.onActivate,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  @override
  State<_FocusableRow> createState() => _FocusableRowState();
}

class _FocusableRowState extends State<_FocusableRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      descendantsAreFocusable: false,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onActivate,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.transparent,
            borderRadius: widget.borderRadius,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _LoadingOverlay extends StatelessWidget {
  final String title;
  final String episodeName;
  final String sourceName;
  final int bufferingSeconds;
  final int? speedBps;

  const _LoadingOverlay({
    required this.title,
    required this.episodeName,
    required this.sourceName,
    this.bufferingSeconds = 0,
    this.speedBps,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (bufferingSeconds >= 2) parts.add('${bufferingSeconds}s');
    final speedLabel = NetworkSpeedMonitor.format(speedBps);
    if (speedLabel.isNotEmpty) parts.add(speedLabel);
    final statusLine = parts.join(' · ');

    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title,
                style: AppTypography.headline2, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Text(episodeName, style: AppTypography.body),
            const SizedBox(height: AppSpacing.lg),
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: AppColors.netflixRed,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(sourceName, style: AppTypography.caption),
            if (statusLine.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                statusLine,
                style: AppTypography.caption.copyWith(
                  color: AppColors.secondaryText,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final FocusNode? focusNode;

  const _Btn({
    required this.icon,
    this.onTap,
    this.size = 32,
    this.focusNode,
  });

  @override
  State<_Btn> createState() => _BtnState();
}

class _BtnState extends State<_Btn> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Focus(
      focusNode: widget.focusNode,
      canRequestFocus: enabled,
      descendantsAreFocusable: false,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            enabled &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Opacity(
            opacity: enabled ? 1.0 : 0.35,
            child: Icon(widget.icon, color: Colors.white, size: widget.size),
          ),
        ),
      ),
    );
  }
}

/// 支持长按加速的 seek 按钮
/// 鼠标：Listener pointer 事件；TV：Focus 监听 Select 的 Down/Up 事件
class _HoldBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  const _HoldBtn({
    required this.icon,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  @override
  State<_HoldBtn> createState() => _HoldBtnState();
}

class _HoldBtnState extends State<_HoldBtn> {
  bool _focused = false;
  bool _holding = false;

  bool _isActivationKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.gameButtonA;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: true,
      descendantsAreFocusable: false,
      onFocusChange: (f) {
        setState(() => _focused = f);
        // 失焦时若仍在 holding，主动停止
        if (!f && _holding) {
          _holding = false;
          widget.onHoldEnd();
        }
      },
      onKeyEvent: (node, event) {
        if (!_isActivationKey(event.logicalKey)) {
          return KeyEventResult.ignored;
        }
        if (event is KeyDownEvent) {
          _holding = true;
          widget.onHoldStart();
          return KeyEventResult.handled;
        } else if (event is KeyUpEvent) {
          if (_holding) {
            _holding = false;
            widget.onHoldEnd();
          }
          return KeyEventResult.handled;
        }
        // 吞掉 KeyRepeatEvent，避免与 _seekHoldTimer 的 150ms 节奏冲突
        return KeyEventResult.handled;
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => widget.onHoldStart(),
        onPointerUp: (_) => widget.onHoldEnd(),
        onPointerCancel: (_) => widget.onHoldEnd(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon, color: Colors.white, size: 32),
        ),
      ),
    );
  }
}

/// 播放失败遮罩
class _ErrorOverlay extends StatelessWidget {
  final String message;
  final String sourceName;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final VoidCallback? onSwitchSource;

  const _ErrorOverlay({
    required this.message,
    required this.sourceName,
    required this.onRetry,
    required this.onBack,
    this.onSwitchSource,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black87,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: AppColors.netflixRed, size: 48),
            const SizedBox(height: AppSpacing.md),
            Text('播放失败', style: AppTypography.headline2),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '$sourceName · $message',
              style: AppTypography.caption,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                if (onSwitchSource != null) ...[
                  const SizedBox(width: AppSpacing.md),
                  ElevatedButton.icon(
                    onPressed: onSwitchSource,
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('换线路'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.surface,
                      foregroundColor: AppColors.primaryText,
                    ),
                  ),
                ],
                const SizedBox(width: AppSpacing.md),
                TextButton(
                  onPressed: onBack,
                  child: const Text('返回', style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 多线路选择器（显示在控制栏右上角）
class _SourceSelector extends StatelessWidget {
  final List<String> sourceNames;
  final int currentIndex;
  final void Function(int) onSelect;

  const _SourceSelector({
    required this.sourceNames,
    required this.currentIndex,
    required this.onSelect,
  });

  String _name(int i) =>
      sourceNames.length > i ? sourceNames[i] : '线路 ${i + 1}';

  @override
  Widget build(BuildContext context) {
    return _FocusableRow(
      onActivate: () => _showPicker(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_name(currentIndex), style: AppTypography.caption),
          const SizedBox(width: 4),
          const Icon(Icons.swap_horiz, color: Colors.white70, size: 16),
        ],
      ),
    );
  }

  void _showPicker(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('切换线路', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: double.maxFinite,
          height: sourceNames.length > 8 ? 400 : null,
          child: ListView.builder(
            shrinkWrap: sourceNames.length <= 8,
            itemCount: sourceNames.length,
            itemBuilder: (_, i) {
              final selected = i == currentIndex;
              return _PickerTile(
                title: _name(i),
                selected: selected,
                autofocus: selected,
                onTap: () {
                  Navigator.of(context).pop();
                  if (i != currentIndex) onSelect(i);
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// HLS 多码率画质选择器
class _QualitySelector extends StatelessWidget {
  final List<VideoQuality> qualities;
  final VideoQuality currentQuality;
  final void Function(VideoQuality) onSelect;

  const _QualitySelector({
    required this.qualities,
    required this.currentQuality,
    required this.onSelect,
  });

  String _label(VideoQuality q) {
    final h = q.height ?? 0;
    if (h >= 2160) return '4K';
    if (h >= 1080) return '1080P';
    if (h >= 720) return '720P';
    if (h >= 480) return '480P';
    if (h >= 360) return '360P';
    return '${h}P';
  }

  String _currentLabel() {
    if (currentQuality.isAuto) return '自动';
    return _label(currentQuality);
  }

  @override
  Widget build(BuildContext context) {
    return _FocusableRow(
      onActivate: () => _showPicker(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hd, color: Colors.white70, size: 16),
          const SizedBox(width: 4),
          Text(_currentLabel(), style: AppTypography.caption),
        ],
      ),
    );
  }

  void _showPicker(BuildContext context) {
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
              selected: currentQuality.isAuto,
              autofocus: currentQuality.isAuto,
              onTap: () {
                Navigator.of(context).pop();
                onSelect(const VideoQuality.auto());
              },
            ),
            ...qualities.map((q) {
              final selected = q.id == currentQuality.id;
              return _PickerTile(
                title: _label(q),
                subtitle: '${q.width}×${q.height}',
                selected: selected,
                autofocus: selected,
                onTap: () {
                  Navigator.of(context).pop();
                  onSelect(q);
                },
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// 倍速选择器（控制栏标题行）
class _SpeedSelector extends StatelessWidget {
  final double currentSpeed;
  final void Function(double) onSelect;

  const _SpeedSelector({
    required this.currentSpeed,
    required this.onSelect,
  });

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  String _label(double s) {
    // 1.0 / 2.0 去掉小数点，其它保留
    if (s == s.truncateToDouble()) return '${s.toInt()}x';
    return '${s}x';
  }

  @override
  Widget build(BuildContext context) {
    return _FocusableRow(
      onActivate: () => _showPicker(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.speed, color: Colors.white70, size: 16),
          const SizedBox(width: 4),
          Text(_label(currentSpeed), style: AppTypography.caption),
        ],
      ),
    );
  }

  void _showPicker(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('播放速度', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _speeds.map((s) {
            final selected = s == currentSpeed;
            return _PickerTile(
              title: _label(s),
              selected: selected,
              autofocus: selected,
              onTap: () {
                Navigator.of(context).pop();
                onSelect(s);
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}
