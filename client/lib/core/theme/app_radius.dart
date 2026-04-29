import 'package:flutter/material.dart';

/// StreamBox 圆角 Token
/// 参考 docs/StreamBox_UI_Design.md
class AppRadius {
  static const double card = 8.0;
  static const double button = 4.0;
  static const double dialog = 12.0;
  static const double tag = 2.0;

  // BorderRadius 便捷常量
  static final cardBorder = BorderRadius.circular(card);
  static final buttonBorder = BorderRadius.circular(button);
  static final dialogBorder = BorderRadius.circular(dialog);
  static final tagBorder = BorderRadius.circular(tag);
}
