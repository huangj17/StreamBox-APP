import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/app_typography.dart';
import 'tv_focus.dart';

/// 行级错误组件
/// 单行加载失败时显示，不影响其他行
/// TV 焦点态：红边框+光晕；OK/Enter/GameA 触发 [onRetry]
class ErrorRail extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorRail({super.key, this.message = '加载失败，按 OK 重试', this.onRetry});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSpacing.cardHeight,
      child: Center(
        child: TvFocusable(
          debugLabel: 'error-rail-retry',
          onActivate: onRetry,
          ensureVisibleOnFocus: false,
          builder: (context, focused) {
            final accent = focused ? AppColors.netflixRed : AppColors.hintText;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              constraints: const BoxConstraints(minWidth: 240),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: focused ? AppColors.surface : Colors.transparent,
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, color: accent, size: 36),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: AppTypography.body.copyWith(color: accent),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
