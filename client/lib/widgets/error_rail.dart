import 'package:flutter/material.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/app_typography.dart';

/// 行级错误组件
/// 单行加载失败时显示，不影响其他行
class ErrorRail extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorRail({
    super.key,
    this.message = '加载失败，按 OK 重试',
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSpacing.cardHeight,
      child: Center(
        child: GestureDetector(
          onTap: onRetry,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                color: AppColors.hintText,
                size: 36,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                style: AppTypography.body.copyWith(color: AppColors.hintText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
