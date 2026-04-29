/// StreamBox 间距 Token
/// 基于 8dp 网格系统
/// 参考 docs/StreamBox_UI_Design.md 间距系统
class AppSpacing {
  static const double xs = 4.0;   // icon 内边距、标签间距
  static const double sm = 8.0;   // 卡片文字间距
  static const double md = 16.0;  // 卡片之间间距
  static const double lg = 24.0;  // 内容行间距
  static const double xl = 40.0;  // 页面左右安全边距
  static const double xxl = 64.0; // Hero Banner 到内容间距

  // 组件尺寸
  static const double navBarHeight = 56.0;
  static const double heroBannerHeight = 540.0;  // 50vh @ 1080p
  static const double controlBarHeight = 120.0;
  static const double settingsSidebarWidth = 280.0;

  // 卡片尺寸
  static const double cardWidth = 160.0;
  static const double cardHeight = 240.0;       // 竖版 2:3
  static const double cardWidthLandscape = 213.0;
  static const double cardHeightLandscape = 120.0; // 横版（继续观看行）

  // 按钮
  static const double buttonHeight = 52.0;
  static const double buttonPaddingH = 24.0;

  // 标签
  static const double tagHeight = 24.0;
  static const double tagPaddingH = 8.0;
  static const double tagPaddingV = 4.0;

  /// 响应式 Grid 列数
  /// XS <800px       → 3 列
  /// SM 800-1279px   → 4 列
  /// MD 1280-1439px  → 5 列
  /// LG 1440-1919px  → 6 列
  /// XL 1920px+      → 7 列
  static int gridColumns(double width) {
    if (width >= 1920) return 7;
    if (width >= 1440) return 6;
    if (width >= 1280) return 5;
    if (width >= 800) return 4;
    return 3;
  }
}
