import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/app_typography.dart';

/// 左侧导航栏（TV / 桌面焦点模式）
///
/// 收起态 80dp 仅图标；焦点进入侧栏自动展开 240dp 显示标签。
/// 焦点离开自动收起（200ms easeOut）。
///
/// 焦点流：
/// - 内容区最左焦点节点按 ← → [firstItemFocusNode]（外部接线）
/// - 侧栏项按 → → 调 [onExitToContent]（外部决定退到内容区哪个节点）
/// - ↑↓ 在侧栏内 cycle
/// - Enter/Select → [onItemSelected]
class SideNavBar extends StatefulWidget {
  /// 当前选中项 index（用于高亮，不影响焦点）
  final int selectedIndex;
  final ValueChanged<int> onItemSelected;

  /// 第一个可聚焦项的 FocusNode（内容区 ← 时用）
  final FocusNode? firstItemFocusNode;

  /// 侧栏项按 → 时调；外部决定退到内容区哪个节点
  final VoidCallback? onExitToContent;

  const SideNavBar({
    super.key,
    required this.selectedIndex,
    required this.onItemSelected,
    this.firstItemFocusNode,
    this.onExitToContent,
  });

  static const _items = <_NavItemSpec>[
    _NavItemSpec(label: '首页', icon: Icons.home_rounded, enabled: true),
    _NavItemSpec(label: '直播', icon: Icons.live_tv_rounded, enabled: false),
    _NavItemSpec(label: '搜索', icon: Icons.search_rounded, enabled: true),
    _NavItemSpec(label: '设置', icon: Icons.settings_rounded, enabled: true),
  ];

  @override
  State<SideNavBar> createState() => _SideNavBarState();
}

class _SideNavBarState extends State<SideNavBar> {
  bool _hovered = false;
  bool _internalFocused = false;

  bool get _expanded => _hovered || _internalFocused;

  void _setHovered(bool v) {
    if (v == _hovered) return;
    setState(() => _hovered = v);
  }

  void _setInternalFocused(bool v) {
    if (v == _internalFocused) return;
    setState(() => _internalFocused = v);
  }

  @override
  Widget build(BuildContext context) {
    final width = _expanded
        ? AppSpacing.sideNavExpandedWidth
        : AppSpacing.sideNavCollapsedWidth;

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: FocusScope(
        // SideNav 内部焦点变化（仅追踪 SideNav 子树，不污染外层 scope）。
        // 外层 jumbo FocusScope.hasFocus 包括 Banner / Rail，不能拿来判断
        // 「鼠标离开时是否仍有焦点」——会永真，导致 hover 离开后不收起
        onFocusChange: _setInternalFocused,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          width: width,
          decoration: BoxDecoration(
            color: AppColors.deepBlack,
            // 展开时投阴影到右侧 content，凸显浮层层次
            boxShadow: _expanded
                ? const [
                    BoxShadow(
                      color: Color(0x99000000),
                      offset: Offset(4, 0),
                      blurRadius: 20,
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Logo（按可用宽度切「S」/「StreamBox」，避免动画中段溢出）
              // 水平内边距 32dp 与下方菜单项 Icon 起点对齐
              // （item: outer pad 8 + redbar 4 + spacer 8 + inner pad 12 = 32）
              Padding(
                padding: const EdgeInsets.only(left: 32, right: 16),
                child: SizedBox(
                  height: 48,
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      final showFull = constraints.maxWidth >= 100;
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: showFull
                            ? Text(
                                'StreamBox',
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: AppTypography.headline2.copyWith(
                                  color: AppColors.netflixRed,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : Text(
                                'S',
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: AppTypography.headline1.copyWith(
                                  color: AppColors.netflixRed,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // 导航项
              for (var i = 0; i < SideNavBar._items.length; i++)
                _SideNavItem(
                  spec: SideNavBar._items[i],
                  isSelected: i == widget.selectedIndex,
                  expanded: _expanded,
                  focusNode: i == 0 ? widget.firstItemFocusNode : null,
                  onTap: SideNavBar._items[i].enabled
                      ? () => widget.onItemSelected(i)
                      : null,
                  onExitRight: widget.onExitToContent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItemSpec {
  final String label;
  final IconData icon;
  final bool enabled;
  const _NavItemSpec({
    required this.label,
    required this.icon,
    required this.enabled,
  });
}

class _SideNavItem extends StatefulWidget {
  final _NavItemSpec spec;
  final bool isSelected;
  final bool expanded;
  final FocusNode? focusNode;
  final VoidCallback? onTap;
  final VoidCallback? onExitRight;

  const _SideNavItem({
    required this.spec,
    required this.isSelected,
    required this.expanded,
    this.focusNode,
    this.onTap,
    this.onExitRight,
  });

  @override
  State<_SideNavItem> createState() => _SideNavItemState();
}

class _SideNavItemState extends State<_SideNavItem> {
  bool _focused = false;
  bool _hovered = false;

  /// 视觉语义分离：
  /// - selected（持久状态）：左侧 4dp 红条 + 红色图标 + 文字 primary。无背景色。
  /// - focused（临时状态）：红色边框 + 浅灰背景。无 boxShadow（避免红光晕渗透
  ///   形成「红底」错觉，焦点切换时也不会有红色淡出残影）。
  /// - hovered：浅灰背景。
  /// 三者可叠加但视觉权重独立、不互相增强。

  Color get _iconColor {
    if (!widget.spec.enabled) return AppColors.hintText;
    if (widget.isSelected) return AppColors.netflixRed;
    if (_focused || _hovered) return AppColors.primaryText;
    return AppColors.secondaryText;
  }

  Color get _labelColor {
    if (!widget.spec.enabled) return AppColors.hintText;
    if (widget.isSelected || _focused || _hovered) return AppColors.primaryText;
    return AppColors.secondaryText;
  }

  Color get _backgroundColor {
    if (_focused || _hovered) return AppColors.surface;
    return Colors.transparent;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      canRequestFocus: widget.spec.enabled,
      onFocusChange: (hasFocus) => setState(() => _focused = hasFocus),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          if (widget.onTap != null) widget.onTap!();
          return KeyEventResult.handled;
        }
        // → 退出到内容区
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (widget.onExitRight != null) {
            widget.onExitRight!();
            return KeyEventResult.handled;
          }
        }
        // ↑↓ 走默认（让 FocusScope 在侧栏内 cycle）
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: widget.spec.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                // 选中红条指示器
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 4,
                  height: 32,
                  decoration: BoxDecoration(
                    color: widget.isSelected
                        ? AppColors.netflixRed
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                // 图标 + 标签容器
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: _backgroundColor,
                      border: Border.all(
                        color: _focused
                            ? AppColors.netflixRed
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    // LayoutBuilder：按实际可用宽度判断显文字。不直接用
                    // widget.expanded，避免动画中段宽度未到位但 expanded=true
                    // 触发 RenderFlex overflow（Icon 24 + Spacer 16 + Text 装不下）
                    child: LayoutBuilder(
                      builder: (ctx, constraints) {
                        final showText = constraints.maxWidth >= 60;
                        return Row(
                          children: [
                            Icon(widget.spec.icon, size: 24, color: _iconColor),
                            if (showText) ...[
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  widget.spec.label,
                                  style: AppTypography.body.copyWith(
                                    color: _labelColor,
                                    fontWeight:
                                        (widget.isSelected ||
                                            _focused ||
                                            _hovered)
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
