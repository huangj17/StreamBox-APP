import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/app_colors.dart';

/// 红光晕 + 红边框可视化样式集，给 [TvFocusRing] 用
enum TvFocusRingShape {
  /// 矩形圆角 8（片源 Tile / 设置项 / 卡片）
  rect,

  /// Chip 胶囊（仓库/插件 chip）
  chip,

  /// 左侧 4dp 红条（SideNav 项专用）— 选中态走左条；焦点态走光晕
  leftBar,
}

/// 统一的 TV 焦点容器：
/// - 监听 Focus + Enter/Select/GameButtonA → onActivate
/// - 焦点变化时 [ensureVisible]：在祖先 Scrollable 中滚动到中间
/// - 支持「长按 OK」触发 [onLongActivate]（默认 500ms）
///
/// 包住 GestureDetector / InkWell，鼠标点击仍走 [onActivate]，与 TV 行为统一。
class TvFocusable extends StatefulWidget {
  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onActivate;
  final VoidCallback? onLongActivate;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool ensureVisibleOnFocus;
  final double ensureVisibleAlignment;
  final Duration longPressThreshold;
  final ValueChanged<bool>? onFocusChange;
  final String? debugLabel;

  /// 是否拦截 Enter/Select/GameA。设为 false 时仅接管视觉 + ensureVisible，
  /// 按键处理交给子内容（例如 Switch / DropdownButton 自身）。
  final bool handleActivation;

  const TvFocusable({
    super.key,
    required this.builder,
    this.onActivate,
    this.onLongActivate,
    this.focusNode,
    this.autofocus = false,
    this.ensureVisibleOnFocus = true,
    this.ensureVisibleAlignment = 0.5,
    this.longPressThreshold = const Duration(milliseconds: 500),
    this.onFocusChange,
    this.debugLabel,
    this.handleActivation = true,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  late FocusNode _node;
  bool _ownsNode = false;
  bool _focused = false;
  Timer? _longPressTimer;
  bool _longTriggered = false;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode(debugLabel: widget.debugLabel);
    _ownsNode = widget.focusNode == null;
    _node.addListener(_handleNodeFocus);
  }

  @override
  void didUpdateWidget(covariant TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _node.removeListener(_handleNodeFocus);
      if (_ownsNode) _node.dispose();
      _node = widget.focusNode ?? FocusNode(debugLabel: widget.debugLabel);
      _ownsNode = widget.focusNode == null;
      _node.addListener(_handleNodeFocus);
    }
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _node.removeListener(_handleNodeFocus);
    if (_ownsNode) _node.dispose();
    super.dispose();
  }

  void _handleNodeFocus() {
    if (_node.hasFocus == _focused) return;
    setState(() => _focused = _node.hasFocus);
    widget.onFocusChange?.call(_node.hasFocus);
    if (_node.hasFocus && widget.ensureVisibleOnFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.maybeOf(context)?.position.ensureVisible(
              context.findRenderObject()!,
              alignment: widget.ensureVisibleAlignment,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
            );
      });
    }
  }

  bool _isActivationKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.handleActivation) return KeyEventResult.ignored;
    if (!_isActivationKey(event.logicalKey)) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _longTriggered = false;
      if (widget.onLongActivate != null) {
        _longPressTimer?.cancel();
        _longPressTimer = Timer(widget.longPressThreshold, () {
          _longTriggered = true;
          widget.onLongActivate!();
        });
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _longPressTimer?.cancel();
      if (!_longTriggered) {
        widget.onActivate?.call();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleTap() {
    widget.onActivate?.call();
  }

  void _handleLongPress() {
    if (widget.onLongActivate != null) {
      widget.onLongActivate!();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!_node.hasFocus) _node.requestFocus();
          _handleTap();
        },
        onLongPress: widget.onLongActivate != null ? _handleLongPress : null,
        child: widget.builder(context, _focused),
      ),
    );
  }
}

/// 统一焦点 / 选中视觉。
/// 选中（[selected]）和焦点（[focused]）**视觉分离**：
/// - selected: 由调用方在 [child] 内部表达（例如 ✓ 图标 / 红字 / 左红条）
/// - focused: 红边框 + 红光晕（配合 [shape]）
///
/// [shape] = leftBar 时不画外边框，靠调用方自己画左红条体现 selected；
/// focused 时画红外框 + 光晕。
class TvFocusRing extends StatelessWidget {
  final bool focused;
  final bool selected;
  final TvFocusRingShape shape;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color background;
  final Color? selectedBackground;

  const TvFocusRing({
    super.key,
    required this.focused,
    required this.selected,
    required this.child,
    this.shape = TvFocusRingShape.rect,
    this.padding,
    this.background = AppColors.cardBackground,
    this.selectedBackground,
  });

  @override
  Widget build(BuildContext context) {
    final radius = switch (shape) {
      TvFocusRingShape.rect => BorderRadius.circular(8),
      TvFocusRingShape.chip => BorderRadius.circular(19),
      TvFocusRingShape.leftBar => BorderRadius.zero,
    };

    final borderColor = focused
        ? AppColors.netflixRed
        : (shape == TvFocusRingShape.leftBar
            ? Colors.transparent
            : Colors.transparent);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: padding,
      decoration: BoxDecoration(
        color: selected
            ? (selectedBackground ?? AppColors.surface)
            : background,
        borderRadius: radius,
        border: shape == TvFocusRingShape.leftBar
            ? null
            : Border.all(color: borderColor, width: 1),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: AppColors.netflixRed.withAlpha(100),
                  blurRadius: shape == TvFocusRingShape.chip ? 10 : 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
