part of 'player_screen.dart';

enum _PlayerPanel { episodes, sources, settings, speed, quality, volume, info }

class _PanelItem {
  final String title;
  final String? subtitle;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _PanelItem(
    this.title, {
    this.subtitle,
    this.icon = Icons.chevron_right,
    this.selected = false,
    required this.onTap,
  });
}

extension _PlayerPanels on _PlayerScreenState {
  Widget _buildPanel() {
    final panel = _panel!;
    final items = <_PanelItem>[];
    var title = '';
    var subtitle = '';
    var initialIndex = 0;
    switch (panel) {
      case _PlayerPanel.episodes:
        title = '选集';
        final episodes = widget.episodeGroups[_groupIndex];
        subtitle = '$_sourceName · 共 ${episodes.length} 集';
        initialIndex = _episodeIndex;
        for (var i = 0; i < episodes.length; i++) {
          items.add(
            _PanelItem(
              episodes[i].name,
              subtitle: i == _episodeIndex ? '正在播放' : null,
              selected: i == _episodeIndex,
              icon: Icons.play_arrow_rounded,
              onTap: () {
                if (i != _episodeIndex) _switchEpisode(_groupIndex, i);
                _closePanel();
              },
            ),
          );
        }
      case _PlayerPanel.sources:
        title = '切换线路';
        subtitle = '${widget.site.name} · 当前：$_sourceName';
        for (var i = 0; i < widget.episodeGroups.length; i++) {
          final group = widget.episodeGroups[i];
          if (group.isEmpty) continue;
          if (i == _groupIndex) initialIndex = items.length;
          items.add(
            _PanelItem(
              widget.sourceNames.length > i
                  ? widget.sourceNames[i]
                  : '线路 ${i + 1}',
              subtitle: i == _groupIndex ? '当前线路' : '${group.length} 集可播放',
              selected: i == _groupIndex,
              icon: Icons.swap_horiz_rounded,
              onTap: () {
                if (i != _groupIndex) {
                  _switchEpisode(i, _episodeIndex.clamp(0, group.length - 1));
                }
                _closePanel();
              },
            ),
          );
        }
      case _PlayerPanel.settings:
        title = '播放设置';
        subtitle = '调整本次播放';
        void addSetting(
          String name,
          String value,
          IconData icon,
          _PlayerPanel target,
        ) {
          final index = items.length;
          items.add(
            _PanelItem(
              name,
              subtitle: value,
              icon: icon,
              onTap: () {
                _settingsPanelIndex = index;
                _openPanel(target);
              },
            ),
          );
        }
        addSetting(
          '播放速度',
          _PlayerScreenState._speedLabel(_playbackSpeed),
          Icons.speed,
          _PlayerPanel.speed,
        );
        if (_qualities.length > 1) {
          addSetting(
            '画质',
            _currentQuality.isAuto
                ? '自动'
                : _PlayerScreenState._qualityLabel(_currentQuality),
            Icons.hd_outlined,
            _PlayerPanel.quality,
          );
        }
        addSetting(
          '音量',
          '${(_volume * 100).round()}%',
          Icons.volume_up_outlined,
          _PlayerPanel.volume,
        );
        addSetting('播放信息', '线路、画质与缓冲状态', Icons.info_outline, _PlayerPanel.info);
        initialIndex = _settingsPanelIndex.clamp(0, items.length - 1);
      case _PlayerPanel.speed:
        title = '播放速度';
        subtitle = '当前 ${_PlayerScreenState._speedLabel(_playbackSpeed)}';
        const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
        initialIndex = speeds
            .indexOf(_playbackSpeed)
            .clamp(0, speeds.length - 1);
        for (final speed in speeds) {
          items.add(
            _PanelItem(
              _PlayerScreenState._speedLabel(speed),
              subtitle: speed == 1 ? '正常速度' : null,
              selected: speed == _playbackSpeed,
              icon: Icons.speed,
              onTap: () {
                _update(() => _playbackSpeed = speed);
                _engine.setRate(speed);
                _closePanel();
              },
            ),
          );
        }
      case _PlayerPanel.quality:
        title = '画质';
        subtitle = '选择此线路提供的画质';
        final qualities = [
          const VideoQuality.auto(),
          ..._qualities.where((q) => !q.isAuto),
        ];
        initialIndex = qualities
            .indexOf(_currentQuality)
            .clamp(0, qualities.length - 1);
        for (final quality in qualities) {
          items.add(
            _PanelItem(
              quality.isAuto ? '自动' : _PlayerScreenState._qualityLabel(quality),
              subtitle: quality.isAuto
                  ? '根据网络状况调整'
                  : '${quality.width ?? "—"} × ${quality.height ?? "—"}',
              selected: quality == _currentQuality,
              icon: Icons.hd_outlined,
              onTap: () {
                _selectQuality(quality);
                _closePanel();
              },
            ),
          );
        }
      case _PlayerPanel.volume:
        title = '音量';
        subtitle = '播放器音量 · 系统音量可用遥控器调节';
        final values = {0, 25, 50, 75, 100, (_volume * 100).round()}.toList()
          ..sort();
        initialIndex = values.indexOf((_volume * 100).round());
        for (final value in values) {
          items.add(
            _PanelItem(
              value == 0 ? '静音' : '$value%',
              selected: value == (_volume * 100).round(),
              icon: value == 0
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
              onTap: () {
                _update(() => _volume = value / 100);
                _engine.setVolume(_volume);
                _closePanel();
              },
            ),
          );
        }
      case _PlayerPanel.info:
        title = '播放信息';
        subtitle = widget.videoTitle;
    }
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: _closePanel,
            child: const ColoredBox(color: Color(0x66000000)),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: _PlayerSidePanel(
            key: ValueKey(panel),
            title: title,
            subtitle: subtitle,
            items: items,
            initialIndex: initialIndex,
            onClose: _closePanel,
            content: panel == _PlayerPanel.info
                ? ValueListenableBuilder<PlaybackProgressState>(
                    valueListenable: _progressState,
                    builder: (_, progress, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _infoLine('片源', widget.site.name),
                        _infoLine('线路', _sourceName),
                        _infoLine('当前集数', _current.name),
                        _infoLine(
                          '播放速度',
                          _PlayerScreenState._speedLabel(_playbackSpeed),
                        ),
                        _infoLine(
                          '画质',
                          _currentQuality.isAuto
                              ? '自动'
                              : _PlayerScreenState._qualityLabel(
                                  _currentQuality,
                                ),
                        ),
                        _infoLine(
                          '播放进度',
                          '${_fmt(progress.position)} / ${_fmt(progress.duration)}',
                        ),
                        _infoLine('已缓冲', '${progress.bufferAhead.inSeconds} 秒'),
                      ],
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _infoLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 15),
        ),
        const SizedBox(height: 6),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 20)),
      ],
    ),
  );
}

/// 独立焦点区域，长列表可直接定位当前集，并导航到尚未构建的项目。
class _PlayerSidePanel extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<_PanelItem> items;
  final int initialIndex;
  final VoidCallback onClose;
  final Widget? content;
  const _PlayerSidePanel({
    super.key,
    required this.title,
    required this.subtitle,
    required this.items,
    required this.initialIndex,
    required this.onClose,
    this.content,
  });
  @override
  State<_PlayerSidePanel> createState() => _PlayerSidePanelState();
}

class _PlayerSidePanelState extends State<_PlayerSidePanel> {
  final _closeNode = FocusNode(debugLabel: 'playerPanel:close');
  late final List<FocusNode> _nodes;
  ScrollController? _scroll;
  late int _index;
  int _focusEpoch = 0;
  double _extent = 88;

  @override
  void initState() {
    super.initState();
    _nodes = List.generate(
      widget.items.length,
      (i) => FocusNode(debugLabel: 'playerPanel:$i'),
    );
    _index = widget.items.isEmpty
        ? -1
        : widget.initialIndex.clamp(0, widget.items.length - 1);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _extent = 88 * MediaQuery.textScalerOf(context).scale(18) / 18;
    if (_scroll == null) {
      _scroll = ScrollController(
        initialScrollOffset: (_index - 1).clamp(0, _nodes.length) * _extent,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusAt(_index);
      });
    }
  }

  @override
  void didUpdateWidget(covariant _PlayerSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length == widget.items.length) return;
    final oldTitle = _index >= 0 && _index < oldWidget.items.length
        ? oldWidget.items[_index].title
        : null;
    while (_nodes.length < widget.items.length) {
      _nodes.add(FocusNode(debugLabel: 'playerPanel:${_nodes.length}'));
    }
    while (_nodes.length > widget.items.length) {
      _nodes.removeLast().dispose();
    }
    final target = widget.items.indexWhere((item) => item.title == oldTitle);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusAt(target);
    });
  }

  @override
  void dispose() {
    _focusEpoch++;
    _closeNode.dispose();
    for (final node in _nodes) {
      node.dispose();
    }
    _scroll?.dispose();
    super.dispose();
  }

  void _focusAt(int index) {
    _index = index.clamp(-1, _nodes.length - 1);
    final epoch = ++_focusEpoch;
    if (_index < 0) {
      _closeNode.requestFocus();
      return;
    }
    final scroll = _scroll!;
    if (scroll.hasClients) {
      final start = _index * _extent;
      final end = start + _extent;
      final offset = start < scroll.offset
          ? start
          : end > scroll.offset + scroll.position.viewportDimension
          ? end - scroll.position.viewportDimension
          : scroll.offset;
      scroll.jumpTo(offset.clamp(0, scroll.position.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && epoch == _focusEpoch) _nodes[_index].requestFocus();
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_isBackKey(key)) {
      if (event is KeyDownEvent) widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      if (widget.content != null) {
        final scroll = _scroll!;
        if (scroll.hasClients) {
          scroll.jumpTo(
            (scroll.offset + (key == LogicalKeyboardKey.arrowDown ? 100 : -100))
                .clamp(0, scroll.position.maxScrollExtent),
          );
        }
      } else {
        _focusAt(_index + (key == LogicalKeyboardKey.arrowDown ? 1 : -1));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.keyM) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = size.width < 600
        ? size.width
        : (size.width * 0.36).clamp(400.0, 520.0);
    return FocusScope(
      onKeyEvent: _onKey,
      child: Container(
        width: width,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: Color(0xFA17171B),
          border: Border(left: BorderSide(color: Colors.white12)),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(size.height < 500 ? 16 : 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _PlayerButton(
                      focusNode: _closeNode,
                      icon: Icons.close,
                      label: '关闭',
                      onTap: widget.onClose,
                      onFocused: () => _index = -1,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  widget.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 16),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: widget.content != null
                      ? SingleChildScrollView(
                          controller: _scroll,
                          child: widget.content,
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemExtent: _extent,
                          itemCount: widget.items.length,
                          itemBuilder: (_, i) => _PanelChoice(
                            node: _nodes[i],
                            item: widget.items[i],
                            onFocused: () => _index = i,
                          ),
                        ),
                ),
                if (size.width >= 700 && size.height >= 500) ...[
                  const SizedBox(height: 20),
                  Text(
                    widget.content != null
                        ? '↑ ↓ 浏览信息    返回 上一层'
                        : '↑ ↓ 选择    OK 确认    返回 上一层',
                    style: const TextStyle(color: Colors.white60, fontSize: 14),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelChoice extends StatefulWidget {
  final FocusNode node;
  final _PanelItem item;
  final VoidCallback onFocused;
  const _PanelChoice({
    required this.node,
    required this.item,
    required this.onFocused,
  });
  @override
  State<_PanelChoice> createState() => _PanelChoiceState();
}

class _PanelChoiceState extends State<_PanelChoice> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focus(
        focusNode: widget.node,
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          if (focused) widget.onFocused();
        },
        onKeyEvent: (_, event) {
          if (!_isConfirmKey(event.logicalKey)) return KeyEventResult.ignored;
          if (event is KeyDownEvent) item.onTap();
          return KeyEventResult.handled;
        },
        child: Semantics(
          button: true,
          selected: item.selected,
          label: item.title,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.node.requestFocus();
              item.onTap();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: _focused
                    ? const Color(0xFF36363C)
                    : item.selected
                    ? const Color(0xFF3B1B22)
                    : const Color(0xFF222226),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _focused ? Colors.white : Colors.transparent,
                  width: 3,
                ),
              ),
              child: Row(
                children: [
                  Icon(item.icon, color: Colors.white70, size: 24),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (item.subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (item.selected) ...[
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.check_circle,
                      color: Color(0xFFFF5262),
                      size: 24,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
