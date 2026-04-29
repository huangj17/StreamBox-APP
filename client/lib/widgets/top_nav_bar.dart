import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/app_typography.dart';

/// 顶部导航栏
/// 默认半透明模糊背景，滚动 >100dp 后变实心
class TopNavBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;
  final bool isOpaque;
  /// 可选：第一项的 FocusNode，便于外部作为方向键「上」的锚点使用
  final FocusNode? firstItemFocusNode;
  /// 可选：按下方向键「下」时要聚焦的目标节点。
  /// 默认方向焦点策略从顶栏按下会按几何距离跳过 Banner 直达 Rail，
  /// 在首页里把这里指到 Banner 播放按钮，保证顶栏 ↓ 会先落到 Banner。
  final FocusNode? downAnchor;

  const TopNavBar({
    super.key,
    required this.selectedIndex,
    required this.onItemSelected,
    this.isOpaque = false,
    this.firstItemFocusNode,
    this.downAnchor,
  });

  static const _items = ['首页', '直播', '搜索', '设置'];

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: isOpaque
            ? ImageFilter.blur()
            : ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          height: AppSpacing.navBarHeight,
          color: isOpaque
              ? AppColors.deepBlack
              : AppColors.deepBlack.withAlpha(178), // 0.7 opacity
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: Row(
            children: [
              // Logo
              Text(
                'StreamBox',
                style: AppTypography.headline2.copyWith(
                  color: AppColors.netflixRed,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // 导航项
              for (var i = 0; i < _items.length; i++) ...[
                _NavItem(
                  label: _items[i],
                  isSelected: i == selectedIndex,
                  onTap: () => onItemSelected(i),
                  focusNode: i == 0 ? firstItemFocusNode : null,
                  downAnchor: downAnchor,
                ),
                if (i < _items.length - 1) const SizedBox(width: AppSpacing.lg),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final FocusNode? downAnchor;

  const _NavItem({
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.focusNode,
    this.downAnchor,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.isSelected || _focused || _hovered;
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (hasFocus) => setState(() => _focused = hasFocus),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        // 按下键显式跳到 downAnchor（首页里是 Banner 播放按钮），
        // 避免默认方向焦点策略按几何距离跳过 Banner 直达 Rail
        if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
            widget.downAnchor != null) {
          widget.downAnchor!.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _focused ? AppColors.netflixRed : Colors.transparent,
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: AppTypography.body.copyWith(
                    color: highlighted
                        ? AppColors.primaryText
                        : AppColors.secondaryText,
                    fontWeight: highlighted ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                // 选中下划线
                Container(
                  height: 2,
                  width: 24,
                  color: widget.isSelected
                      ? AppColors.netflixRed
                      : Colors.transparent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
