import 'package:flutter/widgets.dart';

/// 首页关键焦点锚点
///
/// SideNav 模式（TV / 桌面焦点）下：
/// - 内容区最左焦点节点 ← → [navFirst]（侧栏第一项）
/// - 侧栏项 → → 调 [requestExitToContent] 退出到内容区
///   - 错误态：优先 [errorRetry]（attached 时有 context）
///   - 否则：[bannerPlay]
class HomeFocusAnchors extends InheritedWidget {
  final FocusNode bannerPlay;

  /// 导航第一项 FocusNode
  final FocusNode navFirst;

  /// 错误态「重试」按钮 FocusNode。始终存在；attach/detach 由错误态 widget
  /// 的 mount 状态决定。[requestExitToContent] 通过 [FocusNode.context] 判断。
  final FocusNode errorRetry;

  /// 显式把 Banner 滚回可视区。仅在「用户主动上行到 Banner」时调用。
  final VoidCallback ensureBannerVisible;

  const HomeFocusAnchors({
    super.key,
    required this.bannerPlay,
    required this.navFirst,
    required this.errorRetry,
    required this.ensureBannerVisible,
    required super.child,
  });

  static HomeFocusAnchors? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<HomeFocusAnchors>();
  }

  /// SideNav → 退出到内容区。
  /// 错误态优先回 [errorRetry]（避免焦点掉进未渲染的 Banner）；
  /// 否则回 [bannerPlay]。
  void requestExitToContent() {
    if (errorRetry.context != null && errorRetry.canRequestFocus) {
      errorRetry.requestFocus();
      return;
    }
    bannerPlay.requestFocus();
    ensureBannerVisible();
  }

  @override
  bool updateShouldNotify(HomeFocusAnchors oldWidget) =>
      bannerPlay != oldWidget.bannerPlay ||
      navFirst != oldWidget.navFirst ||
      errorRetry != oldWidget.errorRetry ||
      ensureBannerVisible != oldWidget.ensureBannerVisible;
}
