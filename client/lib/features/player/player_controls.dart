part of 'player_screen.dart';

extension _PlayerControls on _PlayerScreenState {
  Widget _control(
    String id,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool primary = false,
  }) {
    return _PlayerButton(
      key: ValueKey('player-$id'),
      focusNode: _actionNode(id),
      icon: icon,
      label: label,
      primary: primary,
      onFocused: () {
        _lastAction = id;
        _scheduleHide();
      },
      onTap: () {
        onTap();
        _scheduleHide();
      },
    );
  }

  Widget _buildControlBar() {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 700 || size.height < 500;
    final hPad = size.width >= 1000 ? 48.0 : 20.0;
    final actions = <Widget>[
      _control(
        'playPause',
        _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        _playing ? '暂停' : '播放',
        () => _engine.playOrPause(),
        primary: true,
      ),
      if (_hasPrev)
        _control('previous', Icons.skip_previous_rounded, '上一集', () {
          _switchEpisode(_groupIndex, _episodeIndex - 1);
          if (!_hasPrev) _restoreControlsFocus();
        }),
      if (_hasNext)
        _control('next', Icons.skip_next_rounded, '下一集', () {
          _switchEpisode(_groupIndex, _episodeIndex + 1);
          if (!_hasNext) _restoreControlsFocus();
        }),
      if (_actionIds.contains('episodes'))
        _control(
          'episodes',
          Icons.video_library_outlined,
          '选集',
          () => _openPanel(_PlayerPanel.episodes),
        ),
      if (_actionIds.contains('sources'))
        _control(
          'sources',
          Icons.swap_horiz_rounded,
          '线路',
          () => _openPanel(_PlayerPanel.sources),
        ),
      _control(
        'settings',
        Icons.tune_rounded,
        '设置',
        () => _openPanel(_PlayerPanel.settings),
      ),
      if (!PlatformService.isTv)
        _control(
          'fullscreen',
          _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          _isFullscreen ? '退出全屏' : '全屏',
          _toggleFullscreen,
        ),
    ];
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xC9000000), Color(0xF5000000)],
          stops: [0, 0.3, 1],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        hPad,
        compact ? 28 : 56,
        hPad,
        compact ? 12 : 28,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.videoTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 22 : 30,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 24),
                  ValueListenableBuilder<_LoadingUiState>(
                    valueListenable: _loadingState,
                    builder: (_, loading, _) => Text(
                      loading.isInitialLoading
                          ? '正在加载'
                          : !_playing
                          ? '已暂停'
                          : loading.isRebuffering
                          ? '正在缓冲'
                          : '正在播放',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_current.name} · ${widget.site.name} · $_sourceName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white70,
                fontSize: compact ? 14 : 18,
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<PlaybackProgressState>(
              valueListenable: _progressState,
              builder: (_, progress, _) => _PlayerTimeline(
                focusNode: _progressFocusNode,
                progress: progress,
                preview: _seekPreview,
                compact: compact,
                format: _fmt,
                onFocused: _scheduleHide,
                onPreview: (value) {
                  _hideTimer?.cancel();
                  _update(() {
                    _seeking = true;
                    _seekKey = null;
                    _seekPreview = Duration(
                      milliseconds: (value * progress.duration.inMilliseconds)
                          .round(),
                    );
                  });
                },
                onCommit: () => _finishSeek(commit: true),
              ),
            ),
            const SizedBox(height: 12),
            // 电视宽屏所有按钮同排；较窄窗口可通过焦点或触摸横向滚动。
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) SizedBox(width: i == 1 ? 20 : 10),
                    actions[i],
                  ],
                ],
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: 18),
              Text(
                _seekPreview != null
                    ? '← → 调整位置    松手跳转    返回 取消'
                    : '↑ 调整进度    ← → 选择操作    OK 确认    返回 收起',
                style: const TextStyle(color: Colors.white60, fontSize: 14),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return ColoredBox(
      color: const Color(0xF0000000),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: Colors.white70,
                    size: 48,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '暂时无法播放',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '$_sourceName · $_error',
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 18),
                  ),
                  const SizedBox(height: 28),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      _PlayerButton(
                        focusNode: _errorNode('retry'),
                        icon: Icons.refresh,
                        label: '重试',
                        primary: true,
                        autofocus: true,
                        onTap: () {
                          _playCurrentEpisode();
                          _restoreControlsFocus();
                        },
                      ),
                      if (_actionIds.contains('sources'))
                        _PlayerButton(
                          focusNode: _errorNode('sources'),
                          icon: Icons.swap_horiz,
                          label: '换线路',
                          onTap: () => _openPanel(_PlayerPanel.sources),
                        ),
                      _PlayerButton(
                        focusNode: _errorNode('back'),
                        icon: Icons.arrow_back,
                        label: '返回',
                        onTap: _exitPlayer,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 白色描边表示焦点，红色标记表示当前选择；所有输入方式共用同一入口。
class _PlayerButton extends StatefulWidget {
  final FocusNode? focusNode;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onFocused;
  final bool primary;
  final bool autofocus;
  const _PlayerButton({
    super.key,
    this.focusNode,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onFocused,
    this.primary = false,
    this.autofocus = false,
  });

  @override
  State<_PlayerButton> createState() => _PlayerButtonState();
}

class _PlayerButtonState extends State<_PlayerButton> {
  bool _focused = false;
  LogicalKeyboardKey? _activationKey;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    autofocus: widget.autofocus,
    onFocusChange: (focused) {
      if (!focused) _activationKey = null;
      setState(() => _focused = focused);
      if (focused) {
        widget.onFocused?.call();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Scrollable.ensureVisible(
              context,
              alignment: 0.5,
              duration: const Duration(milliseconds: 140),
            );
          }
        });
      }
    },
    onKeyEvent: (_, event) {
      if (!_isConfirmKey(event.logicalKey)) return KeyEventResult.ignored;
      if (event.synthesized) {
        _activationKey = null;
      } else if (event is KeyDownEvent) {
        _activationKey = event.logicalKey;
      } else if (event is KeyUpEvent && _activationKey == event.logicalKey) {
        // 松键后再切换路由，避免详情页收到同一次确认键的尾部事件。
        _activationKey = null;
        widget.onTap();
      }
      return KeyEventResult.handled;
    },
    child: Semantics(
      button: true,
      label: widget.label,
      focused: _focused,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _activationKey = null;
          widget.focusNode?.requestFocus();
          widget.onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: widget.primary && !_focused
                ? Colors.white
                : _focused
                ? const Color(0xFF414145)
                : const Color(0xD9252528),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 3,
            ),
            boxShadow: _focused
                ? [
                    const BoxShadow(
                      color: Colors.black54,
                      blurRadius: 0,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  color: widget.primary && !_focused
                      ? Colors.black
                      : Colors.white,
                  size: 26,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.primary && !_focused
                        ? Colors.black
                        : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
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

class _PlayerTimeline extends StatefulWidget {
  final FocusNode focusNode;
  final PlaybackProgressState progress;
  final Duration? preview;
  final bool compact;
  final String Function(Duration) format;
  final VoidCallback onFocused;
  final ValueChanged<double> onPreview;
  final VoidCallback onCommit;
  const _PlayerTimeline({
    required this.focusNode,
    required this.progress,
    required this.preview,
    required this.compact,
    required this.format,
    required this.onFocused,
    required this.onPreview,
    required this.onCommit,
  });
  @override
  State<_PlayerTimeline> createState() => _PlayerTimelineState();
}

class _PlayerTimelineState extends State<_PlayerTimeline> {
  bool _focused = false;

  Widget _timeLabel(String value, Color color) => Text(
    value,
    style: TextStyle(
      color: color,
      fontSize: widget.compact ? 15 : 18,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );

  Widget _hint(int seconds) => Text(
    widget.preview != null
        ? '${seconds >= 0 ? '+' : ''}${seconds}s · 松手跳转'
        : _focused
        ? '左右调整 · 松手跳转'
        : '',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(color: Colors.white70, fontSize: widget.compact ? 13 : 16),
  );

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final position = widget.preview ?? progress.position;
    final value = progress.hasKnownDuration
        ? (position.inMilliseconds / progress.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final seconds = widget.preview == null
        ? 0
        : (widget.preview! - progress.position).inSeconds;
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused();
      },
      child: Semantics(
        label: '播放进度',
        value: widget.format(position),
        child: Container(
          key: const ValueKey('player-timeline'),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.transparent,
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.compact) ...[
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    children: [
                      _timeLabel(widget.format(position), Colors.white),
                      _timeLabel(
                        progress.hasKnownDuration
                            ? widget.format(progress.duration)
                            : '时长未知',
                        Colors.white70,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerLeft, child: _hint(seconds)),
              ] else
                Row(
                  children: [
                    _timeLabel(widget.format(position), Colors.white),
                    const SizedBox(width: 16),
                    Expanded(child: _hint(seconds)),
                    _timeLabel(
                      progress.hasKnownDuration
                          ? widget.format(progress.duration)
                          : '时长未知',
                      Colors.white70,
                    ),
                  ],
                ),
              ExcludeFocus(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: _focused ? 6 : 4,
                    activeTrackColor: AppColors.netflixRed,
                    inactiveTrackColor: Colors.white24,
                    secondaryActiveTrackColor: Colors.white54,
                    thumbColor: _focused ? Colors.white : AppColors.netflixRed,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: _focused ? 8 : 6,
                    ),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(
                    value: value,
                    secondaryTrackValue: progress.bufferedRatio.clamp(
                      value,
                      1.0,
                    ),
                    onChanged: progress.hasKnownDuration
                        ? widget.onPreview
                        : null,
                    onChangeStart: progress.hasKnownDuration
                        ? (_) => widget.focusNode.requestFocus()
                        : null,
                    onChangeEnd: progress.hasKnownDuration
                        ? (_) => widget.onCommit()
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
