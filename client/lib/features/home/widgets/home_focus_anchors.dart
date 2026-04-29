import 'package:flutter/widgets.dart';

/// 首页关键焦点锚点
///
/// Flutter 的 `DirectionalFocusTraversalPolicyMixin.inDirection(up)` 按几何距离
/// 挑候选节点，Banner 按钮与 TopNavBar 的水平偏移较大、且 `Scrollable.ensureVisible`
/// 滚动后几何关系会被拉扁，方向键「上」常找不到合适候选。
///
/// 在子组件里直接 `requestFocus` 这些锚点作为兜底，可保证：
/// - VideoCard 上键默认失败时跳回 Banner 播放按钮
/// - Banner 按钮上键直接跳到顶栏「首页」
class HomeFocusAnchors extends InheritedWidget {
  final FocusNode bannerPlay;
  final FocusNode topNavFirst;
  /// 显式把 Banner 滚回可视区。仅在「用户主动上行到 Banner」时调用，
  /// 不要挂在 Banner 按钮的 onFocusChange 里——路由 pop 回 Home 时 Banner
  /// 按钮会重新获得焦点，挂在 onFocusChange 上会被误触发成「回到顶部」。
  final VoidCallback ensureBannerVisible;

  const HomeFocusAnchors({
    super.key,
    required this.bannerPlay,
    required this.topNavFirst,
    required this.ensureBannerVisible,
    required super.child,
  });

  static HomeFocusAnchors? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<HomeFocusAnchors>();
  }

  @override
  bool updateShouldNotify(HomeFocusAnchors oldWidget) =>
      bannerPlay != oldWidget.bannerPlay ||
      topNavFirst != oldWidget.topNavFirst ||
      ensureBannerVisible != oldWidget.ensureBannerVisible;
}
