import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_typography.dart';
import 'app_radius.dart';
import 'app_spacing.dart';

/// StreamBox 主题
/// 组装 ThemeData，整合颜色、字体、间距、圆角 Token
class AppTheme {
  static ThemeData get dark => ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.deepBlack,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.netflixRed,
          surface: AppColors.surface,
          error: AppColors.error,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.cardBackground,
          elevation: 0,
          titleTextStyle: AppTypography.title,
        ),
        cardTheme: CardThemeData(
          color: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.cardBorder,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryText,
            foregroundColor: Colors.black,
            minimumSize: const Size(0, AppSpacing.buttonHeight),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.buttonPaddingH),
            shape: RoundedRectangleBorder(
              borderRadius: AppRadius.buttonBorder,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primaryText,
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: AppColors.surface,
          labelStyle: AppTypography.caption.copyWith(color: AppColors.primaryText),
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.buttonBorder,
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: AppColors.divider,
          thickness: 1,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppColors.netflixRed,
        ),
        textTheme: const TextTheme(
          displayLarge: AppTypography.display,
          headlineLarge: AppTypography.headline1,
          headlineMedium: AppTypography.headline2,
          titleLarge: AppTypography.title,
          bodyMedium: AppTypography.body,
          bodySmall: AppTypography.caption,
        ),
      );
}
