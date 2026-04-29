import 'package:flutter/material.dart';

/// StreamBox 颜色 Token
/// 参考 docs/StreamBox_UI_Design.md 色彩系统
class AppColors {
  // 品牌色
  static const netflixRed = Color(0xFFE50914);

  // 背景色阶
  static const deepBlack = Color(0xFF0A0A0A);
  static const cardBackground = Color(0xFF1A1A1A);
  static const surface = Color(0xFF242424);
  static const elevatedSurface = Color(0xFF2E2E2E);

  // 文字色阶
  static const primaryText = Color(0xFFFFFFFF);
  static const secondaryText = Color(0xFFB3B3B3);
  static const hintText = Color(0xFF666666);
  static const divider = Color(0xFF333333);

  // 语义色
  static const success = Color(0xFF46D369);
  static const warning = Color(0xFFFFA500);
  static const error = Color(0xFFE50914);
  static const info = Color(0xFF0080FF);

  // 遮罩
  static const overlay = Color(0x99000000); // rgba(0,0,0,0.6)

  // 渐变
  static const heroBottomGradient = [Colors.transparent, deepBlack];
  static const heroLeftGradient = [Colors.transparent, deepBlack];
  static const cardHoverGradient = [Colors.transparent, Color(0xCC000000)];
}
