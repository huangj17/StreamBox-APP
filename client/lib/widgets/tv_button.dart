import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import 'tv_focus.dart';

/// 统一 TV 焦点按钮：自绘容器 + [TvFocusable] + 红环+光晕。
///
/// 替代散落各处的 `ElevatedButton + WidgetStateProperty(focused)` 内联焦点样式。
/// 详情页主操作 / 搜索按钮 / 错误态重试 / 空态刷新 等场景统一复用。
///
/// 颜色规范（默认值参考 [TvButtonStyle]）：
/// - primary：白底黑字（详情页"播放"等）
/// - secondary：半透灰底白字（详情页"从头播放" / "收藏"等）
/// - red：Netflix 红底白字（已收藏 / 主 CTA 强调）
/// - text：透明底，仅 focus 时出红环（"清空" 这类轻量动作）
class TvActionButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final bool compact;
  final Color background;
  final Color foreground;
  final bool autofocus;
  final bool ensureVisibleOnFocus;
  final String? debugLabel;
  final VoidCallback? onActivate;
  final VoidCallback? onLongActivate;

  const TvActionButton({
    super.key,
    required this.label,
    required this.onActivate,
    this.icon,
    this.compact = false,
    this.background = AppColors.cardBackground,
    this.foreground = AppColors.primaryText,
    this.autofocus = false,
    this.ensureVisibleOnFocus = true,
    this.debugLabel,
    this.onLongActivate,
  });

  /// 主操作（白底黑字）
  factory TvActionButton.primary({
    Key? key,
    IconData? icon,
    required String label,
    required VoidCallback? onActivate,
    bool compact = false,
    bool autofocus = false,
    String? debugLabel,
    VoidCallback? onLongActivate,
  }) =>
      TvActionButton(
        key: key,
        icon: icon,
        label: label,
        onActivate: onActivate,
        compact: compact,
        autofocus: autofocus,
        background: Colors.white,
        foreground: Colors.black,
        debugLabel: debugLabel,
        onLongActivate: onLongActivate,
      );

  /// 次操作（半透灰底白字）
  factory TvActionButton.secondary({
    Key? key,
    IconData? icon,
    required String label,
    required VoidCallback? onActivate,
    bool compact = false,
    bool autofocus = false,
    String? debugLabel,
    VoidCallback? onLongActivate,
  }) =>
      TvActionButton(
        key: key,
        icon: icon,
        label: label,
        onActivate: onActivate,
        compact: compact,
        autofocus: autofocus,
        background: const Color(0xB36D6D6E),
        foreground: AppColors.primaryText,
        debugLabel: debugLabel,
        onLongActivate: onLongActivate,
      );

  /// 红色强调（已收藏 / 强 CTA）
  factory TvActionButton.red({
    Key? key,
    IconData? icon,
    required String label,
    required VoidCallback? onActivate,
    bool compact = false,
    bool autofocus = false,
    String? debugLabel,
    VoidCallback? onLongActivate,
  }) =>
      TvActionButton(
        key: key,
        icon: icon,
        label: label,
        onActivate: onActivate,
        compact: compact,
        autofocus: autofocus,
        background: AppColors.netflixRed.withAlpha(178),
        foreground: AppColors.primaryText,
        debugLabel: debugLabel,
        onLongActivate: onLongActivate,
      );

  /// 文字型（透明底，focus 时显红环）
  factory TvActionButton.text({
    Key? key,
    IconData? icon,
    required String label,
    required VoidCallback? onActivate,
    bool compact = true,
    bool autofocus = false,
    String? debugLabel,
    VoidCallback? onLongActivate,
  }) =>
      TvActionButton(
        key: key,
        icon: icon,
        label: label,
        onActivate: onActivate,
        compact: compact,
        autofocus: autofocus,
        background: Colors.transparent,
        foreground: AppColors.hintText,
        debugLabel: debugLabel,
        onLongActivate: onLongActivate,
      );

  @override
  Widget build(BuildContext context) {
    final iconSize = compact ? 18.0 : 24.0;
    final fontSize = compact ? 14.0 : 16.0;
    final hPad = compact ? AppSpacing.md : AppSpacing.lg;
    final vPad = compact ? 8.0 : 12.0;

    return TvFocusable(
      debugLabel: debugLabel,
      autofocus: autofocus,
      onActivate: onActivate,
      onLongActivate: onLongActivate,
      ensureVisibleOnFocus: ensureVisibleOnFocus,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused ? AppColors.netflixRed : Colors.transparent,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: iconSize, color: foreground),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
