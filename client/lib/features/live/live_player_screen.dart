import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../core/platform/platform_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/live_channel.dart';
import '../home/providers/categories_provider.dart';
import '../player/engine/video_engine.dart';
import '../player/engine/video_engine_factory.dart';
import '../player/player_buffering.dart';
import 'live_widgets.dart';
import 'live_catalog.dart';
import 'live_choice_dialog.dart';
import 'live_channel_panel.dart';
import 'live_playback_error.dart';
import 'providers/live_provider.dart';

class LivePlaybackRequest {
  final List<LiveChannel> channels;
  final int initialIndex;
  final String subscriptionUrl;
  final String subscriptionName;
  const LivePlaybackRequest({
    required this.channels,
    required this.initialIndex,
    required this.subscriptionUrl,
    required this.subscriptionName,
  });
}

/// Live playback shares the video engines, while keeping channel navigation and
/// lifecycle separate from VOD resume, episode completion, and seeking.
class LivePlayerScreen extends ConsumerStatefulWidget {
  final LivePlaybackRequest request;
  final VoidCallback onExit;
  final ValueChanged<int> onSettings;
  const LivePlayerScreen({
    super.key,
    required this.request,
    required this.onExit,
    required this.onSettings,
  });
  @override
  ConsumerState<LivePlayerScreen> createState() => _LivePlayerScreenState();
}

class _LivePlayerScreenState extends ConsumerState<LivePlayerScreen>
    with WidgetsBindingObserver {
  final _root = FocusNode(debugLabel: 'livePlayer:root');
  final _retry = FocusNode(debugLabel: 'livePlayer:retry');
  final _errorNext = FocusNode(debugLabel: 'livePlayer:errorNext');
  final _switchSubscription = FocusNode(
    debugLabel: 'livePlayer:switchSubscription',
  );
  final _channelButton = FocusNode(debugLabel: 'livePlayer:channels');
  final _previous = FocusNode(debugLabel: 'livePlayer:previous');
  final _next = FocusNode(debugLabel: 'livePlayer:next');
  final _lineButton = FocusNode(debugLabel: 'livePlayer:line');
  final _settingsButton = FocusNode(debugLabel: 'livePlayer:settings');
  final _exitButton = FocusNode(debugLabel: 'livePlayer:exit');
  late final LiveCatalog _catalog;
  final _selectedLines = <int, int>{};
  final _attemptedLines = <int>{};
  bool _automaticSwitch = false;
  bool _choosingLine = false;
  final _subscriptions = <StreamSubscription>[];
  VideoEngine? _engine;
  Widget? _surface;
  Timer? _timeout;
  Timer? _hideTimer;
  late int _index;
  int _generation = 0;
  bool _panel = false;
  bool _controls = true;
  bool _loading = true;
  bool _failed = false;
  bool _allowExit = false;
  bool _foreground = true;
  String _failureMessage = '';

  LiveChannel get _channel => widget.request.channels[_index];
  int get _station => _catalog.stationForLine(_index);
  List<int> get _lines => _catalog.stations[_station].lines;

  void _switchChannel(int direction) {
    final station =
        (_station + direction + _catalog.stations.length) %
        _catalog.stations.length;
    _play(_selectedLines[station] ?? _catalog.stations[station].lines.first);
  }

  void _settings() => widget.onSettings(_index);

  Future<void> _chooseLine() async {
    _hideTimer?.cancel();
    _choosingLine = true;
    final lines = [..._lines];
    final index = await showDialog<int>(
      context: context,
      builder: (_) => LiveChoiceDialog(
        title: '${_channel.name} · 播放线路',
        labels: [for (var i = 0; i < lines.length; i++) '线路 ${i + 1}'],
        selected: lines.indexOf(_index),
      ),
    );
    if (!mounted) return;
    _choosingLine = false;
    if (index != null) {
      _play(lines[index]);
    } else {
      _lineButton.requestFocus();
      _scheduleHide();
    }
  }

  @override
  void initState() {
    super.initState();
    _catalog = LiveCatalog(widget.request.channels);
    _index = widget.request.initialIndex.clamp(
      0,
      widget.request.channels.length - 1,
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(WakelockPlus.enable());
    unawaited(PlatformService.setKeepScreenOn(true));
    if (PlatformService.isTv) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    }
    _play(_index);
  }

  Future<void> _releaseEngine() async {
    final old = _engine;
    _engine = null;
    final listeners = [..._subscriptions];
    _subscriptions.clear();
    for (final listener in listeners) {
      unawaited(listener.cancel());
    }
    if (old != null) {
      try {
        await old.dispose();
      } catch (error) {
        debugPrint('释放直播播放器失败: $error');
      }
    }
  }

  Future<void> _play(int index, {bool automatic = false}) async {
    final generation = ++_generation;
    if (!automatic) _attemptedLines.clear();
    _timeout?.cancel();
    _hideTimer?.cancel();
    // Each attempt has its own engine and listeners. Slow/failed older channels
    // cannot publish a surface or error after a rapid remote channel switch.
    unawaited(_releaseEngine());
    setState(() {
      _index =
          (index + widget.request.channels.length) %
          widget.request.channels.length;
      _loading = true;
      _failed = false;
      _controls = true;
      _surface = null;
      _automaticSwitch = automatic;
    });
    _attemptedLines.add(_index);
    if (!automatic) _selectedLines[_station] = _index;
    if (!_panel && !_choosingLine) _root.requestFocus();
    bool current() =>
        mounted && _foreground && !_allowExit && generation == _generation;
    final evidence = PlaybackProgressEvidence();
    var observing = false;
    void armTimeout() {
      _timeout?.cancel();
      _timeout = Timer(const Duration(seconds: 25), () {
        if (current()) _fail(TimeoutException('等待直播画面超时'));
      });
    }

    armTimeout();
    try {
      // Yield before creating an engine. Synchronous factory failures cannot
      // recursively exhaust a large list, and superseded attempts create none.
      await Future<void>.value();
      if (!current()) return;
      final engine = ref.read(videoEngineFactoryProvider)(
        hardwareDecode: ref.read(playerSettingsStorageProvider).hardwareDecode,
      );
      _engine = engine;
      _surface = engine.buildVideoView();
      _subscriptions.add(
        engine.errorStream.listen((error) {
          if (current()) {
            debugPrint('直播播放失败: $error');
            _fail(error);
          }
        }),
      );
      _subscriptions.add(
        engine.bufferingStream.listen((buffering) {
          if (!current() || _failed || !buffering || _loading) return;
          observing = false;
          setState(() => _loading = true);
          armTimeout();
        }),
      );
      _subscriptions.add(
        engine.positionStream.listen((position) {
          if (!current() || _failed || !_loading) return;
          if (!observing) {
            evidence.arm(position);
            observing = true;
          }
          if (evidence.observe(position)) {
            _timeout?.cancel();
            setState(() => _loading = false);
            _selectedLines[_station] = _index;
            unawaited(
              ref
                  .read(liveStorageProvider)
                  .rememberChannel(widget.request.subscriptionUrl, _channel),
            );
            _scheduleHide();
          }
        }),
      );
      setState(() {});
      await engine
          .open(_channel.url, headers: _channel.headers)
          .timeout(const Duration(seconds: 25));
    } catch (error) {
      if (current()) {
        debugPrint('打开直播失败: $error');
        _fail(error);
      }
    }
  }

  void _fail(Object error) {
    if (!mounted || !_foreground || _allowExit || _failed) return;
    _timeout?.cancel();
    _hideTimer?.cancel();
    // Continue from the current line, wrapping once. A manual selection,
    // channel change or explicit retry begins a fresh attempt cycle.
    final lines = _lines;
    final current = lines.indexOf(_index);
    for (var offset = 1; offset < lines.length; offset++) {
      final next = lines[(current + offset) % lines.length];
      if (!_attemptedLines.contains(next)) {
        unawaited(_play(next, automatic: true));
        return;
      }
    }
    // No engine from an exhausted cycle can later publish a picture or launch
    // another attempt. Releasing it also stops a failed stream behind the UI.
    _generation++;
    unawaited(_releaseEngine());
    setState(() {
      _failed = true;
      _loading = false;
      _controls = true;
      _surface = null;
      _failureMessage =
          '${lines.length > 1 ? '已尝试全部 ${lines.length} 条线路。\n' : ''}'
          '${livePlaybackErrorMessage(error, _channel.url)}';
    });
    if (!_panel && !_choosingLine) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _failed) _retry.requestFocus();
      });
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_panel || _choosingLine || _loading || _failed) return;
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _panel || _choosingLine || _failed) return;
      _root.requestFocus();
      setState(() => _controls = false);
    });
  }

  void _showPanel() {
    _hideTimer?.cancel();
    setState(() {
      _panel = true;
      _controls = true;
    });
  }

  void _closePanel() {
    setState(() => _panel = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_failed ? _retry : _root).requestFocus();
      _scheduleHide();
    });
  }

  void _back() {
    if (_panel) {
      _closePanel();
      return;
    }
    if (_allowExit) return;
    setState(() => _allowExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onExit();
      }
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (isLiveBackKey(key)) {
      if (event is KeyDownEvent) _back();
      return KeyEventResult.handled;
    }
    if (_panel) return KeyEventResult.ignored;
    if (_choosingLine) return KeyEventResult.ignored;
    if (_failed &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      if (event is KeyDownEvent) {
        final actions = [
          _retry,
          _errorNext,
          _channelButton,
          if (_lines.length > 1) _lineButton,
          _switchSubscription,
        ];
        final current = actions.indexWhere((n) => n.hasPrimaryFocus);
        final direction = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
        actions[(current + direction).clamp(0, actions.length - 1)]
            .requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.channelUp ||
        key == LogicalKeyboardKey.channelDown) {
      if (event is KeyDownEvent) {
        _switchChannel(
          ((key == LogicalKeyboardKey.arrowUp ||
                  key == LogicalKeyboardKey.channelUp)
              ? -1
              : 1),
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyDownEvent && _root.hasPrimaryFocus) _showPanel();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight) &&
        _root.hasPrimaryFocus) {
      if (event is KeyDownEvent) {
        if (key == LogicalKeyboardKey.arrowLeft) {
          _showPanel();
        } else {
          setState(() => _controls = true);
          _channelButton.requestFocus();
          _scheduleHide();
        }
      }
      return KeyEventResult.handled;
    }
    if (!_failed &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      if (event is KeyDownEvent) {
        final actions = [
          _channelButton,
          _previous,
          _next,
          if (_lines.length > 1) _lineButton,
          _settingsButton,
          _exitButton,
        ];
        final index = actions.indexWhere((n) => n.hasPrimaryFocus);
        if (index >= 0) {
          actions[(index + (key == LogicalKeyboardKey.arrowRight ? 1 : -1))
                  .clamp(0, actions.length - 1)]
              .requestFocus();
        }
        _scheduleHide();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) _scheduleHide();
    return KeyEventResult.ignored;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_foreground) {
        _foreground = true;
        _play(_index);
      }
    } else if (state == AppLifecycleState.paused) {
      _foreground = false;
      _generation++;
      _timeout?.cancel();
      _hideTimer?.cancel();
      unawaited(_engine?.pause().catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    _hideTimer?.cancel();
    unawaited(_releaseEngine());
    unawaited(WakelockPlus.disable());
    unawaited(PlatformService.setKeepScreenOn(false));
    if (PlatformService.isTv) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    for (final node in [
      _root,
      _retry,
      _errorNext,
      _switchSubscription,
      _channelButton,
      _previous,
      _next,
      _lineButton,
      _settingsButton,
      _exitButton,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowExit,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _root,
        autofocus: true,
        onKeyEvent: _key,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _controls = true);
            _scheduleHide();
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 760;
              return Stack(
                fit: StackFit.expand,
                children: [
                  ?_surface,
                  if (_loading)
                    Align(
                      alignment: Alignment(0, -0.5),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 24),
                          Text(
                            _automaticSwitch ? '正在尝试备用线路…' : '正在连接直播…',
                            style: AppTypography.title,
                          ),
                          if (_lines.length > 1)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '线路 ${_lines.indexOf(_index) + 1}/${_lines.length}',
                                style: AppTypography.body,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ExcludeFocus(
                    excluding: _panel,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_failed)
                          Center(
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 720),
                              margin: const EdgeInsets.all(24),
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: AppColors.overlay,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.wifi_off,
                                      size: 48,
                                      color: AppColors.secondaryText,
                                    ),
                                    const SizedBox(height: 16),
                                    const Text(
                                      '该频道暂时无法播放',
                                      style: AppTypography.headline2,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${_channel.name} · ${widget.request.subscriptionName}',
                                      style: AppTypography.title,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _failureMessage,
                                      style: AppTypography.body,
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 24),
                                    Wrap(
                                      spacing: 16,
                                      runSpacing: 12,
                                      alignment: WrapAlignment.center,
                                      children: [
                                        LiveButton(
                                          label: '重试',
                                          icon: Icons.refresh,
                                          focusNode: _retry,
                                          onActivate: () => _play(_index),
                                        ),
                                        LiveButton(
                                          label: '下一频道',
                                          focusNode: _errorNext,
                                          icon: Icons.skip_next,
                                          onActivate: () => _switchChannel(1),
                                        ),
                                        LiveButton(
                                          label: '频道列表',
                                          icon: Icons.list,
                                          focusNode: _channelButton,
                                          onActivate: _showPanel,
                                        ),
                                        if (_lines.length > 1)
                                          LiveButton(
                                            label: '更换线路',
                                            icon: Icons.alt_route,
                                            focusNode: _lineButton,
                                            onActivate: _chooseLine,
                                          ),
                                        LiveButton(
                                          label: '更换订阅',
                                          focusNode: _switchSubscription,
                                          icon: Icons.video_library_outlined,
                                          onActivate: _settings,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (_controls && !_failed && !_panel)
                          SafeArea(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: double.infinity,
                                padding: EdgeInsets.all(compact ? 16 : 40),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Colors.transparent, Colors.black],
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${(_station + 1).toString().padLeft(2, '0')}  ${_channel.name}',
                                      style: compact
                                          ? AppTypography.title
                                          : AppTypography.headline1,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${_channel.group} · 直播',
                                      style: AppTypography.body,
                                    ),
                                    const SizedBox(height: 16),
                                    Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        LiveButton(
                                          label: '频道列表',
                                          icon: Icons.list,
                                          focusNode: _channelButton,
                                          onActivate: _showPanel,
                                        ),
                                        LiveButton(
                                          label: '上一频道',
                                          icon: Icons.skip_previous,
                                          focusNode: _previous,
                                          onActivate: () => _switchChannel(-1),
                                        ),
                                        LiveButton(
                                          label: '下一频道',
                                          icon: Icons.skip_next,
                                          focusNode: _next,
                                          onActivate: () => _switchChannel(1),
                                        ),
                                        if (_lines.length > 1)
                                          LiveButton(
                                            label:
                                                '线路 ${_lines.indexOf(_index) + 1}/${_lines.length}',
                                            icon: Icons.alt_route,
                                            focusNode: _lineButton,
                                            onActivate: _chooseLine,
                                          ),
                                        LiveButton(
                                          label: '直播设置',
                                          icon: Icons.settings_outlined,
                                          focusNode: _settingsButton,
                                          onActivate: _settings,
                                        ),
                                        LiveButton(
                                          label: '返回',
                                          icon: Icons.arrow_back,
                                          focusNode: _exitButton,
                                          onActivate: _back,
                                        ),
                                      ],
                                    ),
                                    if (!compact)
                                      const Padding(
                                        padding: EdgeInsets.only(top: 16),
                                        child: Text(
                                          '↑↓ 切台 · 确认打开频道列表 · 返回退出',
                                          style: AppTypography.body,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_panel) ...[
                    GestureDetector(
                      onTap: _closePanel,
                      child: const ColoredBox(color: AppColors.overlay),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: LiveChannelPanel(
                        catalog: _catalog,
                        currentStation: _station,
                        onClose: _closePanel,
                        onSelect: (station) {
                          _closePanel();
                          _play(
                            _selectedLines[station] ??
                                _catalog.stations[station].lines.first,
                          );
                        },
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
