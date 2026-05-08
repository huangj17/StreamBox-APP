import 'package:flutter/widgets.dart';

/// 首页关键焦点锚点
///
/// SideNav 模式（TV / 桌面焦点）下：
/// - 内容区最左焦点节点 ← → [navFirst]（侧栏第一项）
/// - 侧栏项 → → 调 [requestExitToContent] 退到 [bannerPlay]
class HomeFocusAnchors extends InheritedWidget {
  final FocusNode bannerPlay;

  /// 导航第一项 FocusNode
  final FocusNode navFirst;

  /// 显式把 Banner 滚回可视区。仅在「用户主动上行到 Banner」时调用。
  final VoidCallback ensureBannerVisible;

  const HomeFocusAnchors({
    super.key,
    required this.bannerPlay,
    required this.navFirst,
    required this.ensureBannerVisible,
    required super.child,
  });

  static HomeFocusAnchors? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<HomeFocusAnchors>();
  }

  /// SideNav → 退出到内容区，统一回 Banner Play。
  /// 不做"记忆来源"是有意为之：复杂度高、焦点节点跨 list builder 失效风险大；
  /// Banner Play 是稳定可达的内容入口，符合预期。
  void requestExitToContent() {
    bannerPlay.requestFocus();
    ensureBannerVisible();
  }

  @override
  bool updateShouldNotify(HomeFocusAnchors oldWidget) =>
      bannerPlay != oldWidget.bannerPlay ||
      navFirst != oldWidget.navFirst ||
      ensureBannerVisible != oldWidget.ensureBannerVisible;
}
