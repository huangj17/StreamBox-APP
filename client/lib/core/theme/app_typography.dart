import 'package:flutter/material.dart';
import 'app_colors.dart';

/// StreamBox 字体 Token
/// 参考 docs/StreamBox_UI_Design.md 字体系统
/// TV 端优化：2-3 米观看距离，字号约为移动端 1.5-2 倍
class AppTypography {
  // Display — Hero Banner 主标题
  static const display = TextStyle(
    fontSize: 48,
    fontWeight: FontWeight.bold,
    height: 1.2,
    color: AppColors.primaryText,
  );

  // Headline 1 — 详情页标题
  static const headline1 = TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.bold,
    height: 1.25,
    color: AppColors.primaryText,
  );

  // Headline 2 — 分类行标题
  static const headline2 = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: AppColors.primaryText,
  );

  // Title — 卡片焦点标题
  static const title = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w500,
    height: 1.4,
    color: AppColors.primaryText,
  );

  // Body — 描述、说明文字
  static const body = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.normal,
    height: 1.5,
    color: AppColors.secondaryText,
  );

  // Caption — 评分、年份、标签
  static const caption = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.normal,
    height: 1.4,
    color: AppColors.secondaryText,
  );
}
