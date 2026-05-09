import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_colors.dart';
import 'tv_focus.dart';

/// 统一 TV 返回按钮：40×40 圆形容器 + 红环+光晕。
///
/// 替代裸 [IconButton]，与详情页 / 后续 AppBar 自定义 leading 风格统一。
/// 默认 [onActivate] = `context.pop()`（go_router）。
class TvBackButton extends StatelessWidget {
  final VoidCallback? onActivate;
  final bool autofocus;
  final bool ensureVisibleOnFocus;
  final String? debugLabel;

  const TvBackButton({
    super.key,
    this.onActivate,
    this.autofocus = false,
    this.ensureVisibleOnFocus = false,
    this.debugLabel,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: debugLabel ?? 'tv-back',
      autofocus: autofocus,
      ensureVisibleOnFocus: ensureVisibleOnFocus,
      onActivate: () {
        if (onActivate != null) {
          onActivate!();
          return;
        }
        if (context.canPop()) context.pop();
      },
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: focused
                ? AppColors.netflixRed.withAlpha(30)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
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
          child: const Icon(
            Icons.arrow_back,
            color: AppColors.primaryText,
            size: 20,
          ),
        );
      },
    );
  }
}
