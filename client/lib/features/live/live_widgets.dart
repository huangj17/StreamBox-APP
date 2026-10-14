import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/live_channel.dart';
import '../../widgets/tv_focus.dart';

bool isLiveBackKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.goBack ||
    key == LogicalKeyboardKey.browserBack ||
    key == LogicalKeyboardKey.gameButtonB;

/// Matches the white focus outline used by the player and settings. The red
/// playing/selected marker remains separate from remote focus.
class LiveFocusSurface extends StatelessWidget {
  final bool focused;
  final bool selected;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color background;
  const LiveFocusSurface({
    super.key,
    required this.focused,
    required this.selected,
    required this.child,
    this.padding,
    this.background = AppColors.cardBackground,
  });
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 150),
    padding: padding,
    decoration: BoxDecoration(
      color: (focused || selected) && background != Colors.white
          ? AppColors.surface
          : background,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color: focused ? Colors.white : Colors.transparent,
        width: 2,
      ),
    ),
    child: child,
  );
}

class LiveButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onActivate;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool primary;
  final String? debugLabel;
  const LiveButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onActivate,
    this.focusNode,
    this.autofocus = false,
    this.primary = false,
    this.debugLabel,
  });

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: focusNode,
    autofocus: autofocus,
    debugLabel: debugLabel,
    onActivate: onActivate,
    builder: (_, focused) => LiveFocusSurface(
      focused: focused,
      selected: false,
      background: primary ? Colors.white : AppColors.cardBackground,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 28),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: primary ? Colors.black : Colors.white),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.body.copyWith(
                  color: primary ? Colors.black : Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class LiveChannelTile extends StatelessWidget {
  final LiveChannel channel;
  final int number;
  final bool focused;
  final bool selected;
  const LiveChannelTile({
    super.key,
    required this.channel,
    required this.number,
    required this.focused,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) => LiveFocusSurface(
    focused: focused,
    selected: selected,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            number.toString().padLeft(2, '0'),
            style: AppTypography.body,
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 48,
          height: 40,
          child: channel.logo == null
              ? const Icon(Icons.live_tv, color: AppColors.secondaryText)
              : CachedNetworkImage(
                  imageUrl: channel.logo!,
                  fit: BoxFit.contain,
                  memCacheWidth: 128,
                  errorWidget: (_, _, _) =>
                      const Icon(Icons.live_tv, color: AppColors.secondaryText),
                ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            channel.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.title,
          ),
        ),
        const SizedBox(width: 8),
        Icon(
          selected ? Icons.check_circle : Icons.play_arrow,
          color: selected ? AppColors.netflixRed : AppColors.secondaryText,
          size: 24,
        ),
      ],
    ),
  );
}

/// Explicit vertical navigation keeps long lazy lists operable with a D-pad.
/// Scroll before attaching the target focus node, including offscreen items.
class LiveFocusList extends StatefulWidget {
  final int count;
  final double itemExtent;
  final String label;
  final Widget Function(int index, bool focused) itemBuilder;
  final ValueChanged<int> onActivate;
  final ValueChanged<int>? onFocused;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final int? autofocusIndex;
  const LiveFocusList({
    super.key,
    required this.count,
    required this.itemBuilder,
    required this.onActivate,
    required this.label,
    this.itemExtent = 88,
    this.onFocused,
    this.onLeft,
    this.onRight,
    this.onUp,
    this.onDown,
    this.autofocusIndex,
  });

  @override
  State<LiveFocusList> createState() => LiveFocusListState();
}

class LiveFocusListState extends State<LiveFocusList> {
  final _scroll = ScrollController();
  final _nodes = <int, FocusNode>{};
  int _index = 0;

  @override
  void initState() {
    super.initState();
    if (widget.autofocusIndex case final int index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusAt(index);
      });
    }
  }

  void focusCurrent() => focusAt(_index);

  void focusAt(int index) {
    if (!mounted || widget.count == 0) return;
    final target = index.clamp(0, widget.count - 1);
    _index = target;
    if (_scroll.hasClients) {
      final position = _scroll.position;
      final top = _index * widget.itemExtent;
      final bottom = top + widget.itemExtent;
      if (top < position.pixels ||
          bottom > position.pixels + position.viewportDimension) {
        _scroll.jumpTo(
          (top - (position.viewportDimension - widget.itemExtent) / 2).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Route focus restoration may focus the previous item during this frame.
      // Keep the requested target independent of that listener's _index update.
      if (mounted) _nodes[target]?.requestFocus();
    });
    // A focus request alone cannot schedule a frame for a detached lazy child.
    setState(() {});
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (![
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
    ].contains(key)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowUp) {
        if (_index == 0) {
          widget.onUp?.call();
        } else {
          focusAt(_index - 1);
        }
      } else if (key == LogicalKeyboardKey.arrowDown) {
        if (_index == widget.count - 1 && widget.onDown != null) {
          widget.onDown!();
        } else {
          focusAt(_index + 1);
        }
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        widget.onLeft?.call();
      } else {
        widget.onRight?.call();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: _key,
    child: ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(8),
      itemCount: widget.count,
      itemExtent: widget.itemExtent,
      itemBuilder: (_, index) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TvFocusable(
          focusNode: _nodes.putIfAbsent(
            index,
            () => FocusNode(debugLabel: '${widget.label}:$index'),
          ),
          ensureVisibleOnFocus: false,
          onFocusChange: (focused) {
            if (focused) {
              _index = index;
              widget.onFocused?.call(index);
            }
          },
          onActivate: () => widget.onActivate(index),
          builder: (_, focused) => widget.itemBuilder(index, focused),
        ),
      ),
    ),
  );
}
