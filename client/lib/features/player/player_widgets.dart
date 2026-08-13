part of 'player_screen.dart';

class _OptionTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool autofocus;

  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<_OptionTile> createState() => _OptionTileState();
}

class _OptionTileState extends State<_OptionTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      descendantsAreFocusable: false,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && _isConfirmKey(event.logicalKey)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 196,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused ? Colors.white : Colors.white12,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: Colors.white, size: 30),
              const SizedBox(height: AppSpacing.md),
              Text(
                widget.title,
                style: AppTypography.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: AppTypography.caption.copyWith(color: Colors.white54),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
        if (event is KeyDownEvent && _isPlayPauseKey(event.logicalKey)) {
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                          color: Colors.white38,
                          fontSize: 12,
                        ),
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
    final parts = <String>['正在缓冲'];
    if (bufferingSeconds >= 2) parts.add('等待 $bufferingSeconds 秒');
    final speedLabel = NetworkSpeedMonitor.format(speedBps);
    if (speedLabel.isNotEmpty) parts.add('应用下行 $speedLabel');
    final statusLine = parts.join(' · ');

    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: AppTypography.headline2,
              textAlign: TextAlign.center,
            ),
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

class _RebufferIndicator extends StatelessWidget {
  final int bufferingSeconds;
  final int? speedBps;

  const _RebufferIndicator({
    required this.bufferingSeconds,
    required this.speedBps,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <String>['正在缓冲'];
    if (bufferingSeconds >= 2) parts.add('等待 $bufferingSeconds 秒');
    final speedLabel = NetworkSpeedMonitor.format(speedBps);
    if (speedLabel.isNotEmpty) parts.add('应用下行 $speedLabel');
    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.only(
            top: AppSpacing.sm,
            right: AppSpacing.md,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.70),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: AppColors.netflixRed,
                  strokeWidth: 2,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                parts.join(' · '),
                style: AppTypography.caption.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BufferAheadLabel extends StatelessWidget {
  final PlaybackProgressState progress;
  final bool compact;

  const _BufferAheadLabel({required this.progress, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (!progress.hasKnownDuration) {
      return Text(
        '时长未知',
        style: AppTypography.caption.copyWith(color: Colors.white54),
      );
    }

    final color = switch (progress.bufferHealth) {
      PlaybackBufferHealth.healthy => Colors.greenAccent,
      PlaybackBufferHealth.low => Colors.amberAccent,
      PlaybackBufferHealth.critical => Colors.redAccent,
      PlaybackBufferHealth.unknown => Colors.white54,
    };
    final seconds = progress.bufferAhead.inSeconds;
    final value = seconds >= 60
        ? '${seconds ~/ 60}分${seconds.remainder(60)}秒'
        : compact
        ? '${seconds}s'
        : '$seconds 秒';
    return Semantics(
      label: '已缓冲 $seconds 秒',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            compact ? '缓存 $value' : '已缓冲 $value',
            style: AppTypography.caption.copyWith(color: Colors.white60),
          ),
        ],
      ),
    );
  }
}

class _Btn extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final FocusNode? focusNode;

  const _Btn({required this.icon, this.onTap, this.size = 32, this.focusNode});

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

class _LeanbackActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool dense;

  const _LeanbackActionButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.dense = false,
  });

  @override
  State<_LeanbackActionButton> createState() => _LeanbackActionButtonState();
}

class _LeanbackActionButtonState extends State<_LeanbackActionButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final iconSize = widget.dense ? 17.0 : 24.0;
    final boxSize = widget.dense ? 36.0 : 48.0;
    final width = widget.dense ? null : 64.0;
    final opacity = enabled ? 1.0 : 0.35;
    return Focus(
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
      child: Opacity(
        opacity: opacity,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: width,
            padding: widget.dense
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 7)
                : EdgeInsets.zero,
            decoration: widget.dense
                ? BoxDecoration(
                    color: _focused
                        ? Colors.white.withValues(alpha: 0.20)
                        : Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _focused ? Colors.white : Colors.transparent,
                      width: 1.5,
                    ),
                  )
                : null,
            child: widget.dense
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, color: Colors.white, size: iconSize),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 86),
                        child: Text(
                          widget.label,
                          style: AppTypography.caption.copyWith(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: boxSize,
                      height: boxSize,
                      decoration: BoxDecoration(
                        color: _focused
                            ? Colors.white.withValues(alpha: 0.20)
                            : Colors.white.withValues(alpha: 0.08),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _focused ? Colors.white : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        widget.icon,
                        color: Colors.white,
                        size: iconSize,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _LeanbackPlayButton extends StatefulWidget {
  final bool playing;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _LeanbackPlayButton({
    required this.playing,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_LeanbackPlayButton> createState() => _LeanbackPlayButtonState();
}

class _LeanbackPlayButtonState extends State<_LeanbackPlayButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
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
          duration: const Duration(milliseconds: 150),
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.24)
                : Colors.white.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Icon(
            widget.playing ? Icons.pause : Icons.play_arrow,
            color: Colors.white,
            size: 38,
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
            const Icon(
              Icons.error_outline,
              color: AppColors.netflixRed,
              size: 48,
            ),
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
            if (PlatformService.isTv)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ErrorActionButton(
                    icon: Icons.refresh,
                    label: '重试',
                    autofocus: true,
                    onTap: onRetry,
                  ),
                  if (onSwitchSource != null) ...[
                    const SizedBox(width: AppSpacing.md),
                    _ErrorActionButton(
                      icon: Icons.swap_horiz,
                      label: '换线路',
                      onTap: onSwitchSource!,
                    ),
                  ],
                  const SizedBox(width: AppSpacing.md),
                  _ErrorActionButton(
                    icon: Icons.arrow_back,
                    label: '返回',
                    onTap: onBack,
                  ),
                ],
              )
            else
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
                    child: const Text(
                      '返回',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool autofocus;
  final VoidCallback onTap;

  const _ErrorActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<_ErrorActionButton> createState() => _ErrorActionButtonState();
}

class _ErrorActionButtonState extends State<_ErrorActionButton> {
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
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.24)
                : Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, color: Colors.white, size: 24),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: AppTypography.body.copyWith(color: Colors.white),
              ),
            ],
          ),
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

  const _SpeedSelector({required this.currentSpeed, required this.onSelect});

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
