import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/platform/platform_service.dart';
import '../../../data/models/video_item.dart';
import '../../../data/models/watch_history.dart';
import '../../../widgets/resolvable_cover.dart';
import 'home_focus_anchors.dart';

/// Netflix 风格视频卡片
/// 常态：海报 + 标题 + 备注标签
/// Hover：微缩放 + 阴影 + 显示元数据
/// Focus：同 Hover + 红色边框
class VideoCard extends StatefulWidget {
  final VideoItem video;
  final WatchHistory? history;
  final VoidCallback onSelected;
  final VoidCallback onFocused;
  final bool autofocus;
  final bool landscape; // 横版模式（继续观看行）
  /// 当 → 键的默认方向焦点找不到可聚焦候选（rail 尾端卡片），调此回调
  /// 作兜底（如跳到本 rail「更多」按钮）。非末尾卡不会触发。
  final VoidCallback? onRightEdge;
  /// ↑ 键优先回调：rail 内任一卡片按 ↑ 时直接跳到本 rail「更多」按钮。
  /// 设置后会覆盖默认几何上行和 Banner 兜底（因为「更多」按钮语义上属于当前 rail）。
  final VoidCallback? onUpEdge;

  const VideoCard({
    super.key,
    required this.video,
    this.history,
    required this.onSelected,
    required this.onFocused,
    this.autofocus = false,
    this.landscape = false,
    this.onRightEdge,
    this.onUpEdge,
  });

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  bool _focused = false;
  bool _hovered = false;

  bool get _highlighted => _focused || _hovered;

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary：隔离每张卡片的重绘，hover/focus 动画不影响其它卡片
    return RepaintBoundary(
      child: _buildFocusableCard(),
    );
  }

  Widget _buildFocusableCard() {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (hasFocus) {
        setState(() => _focused = hasFocus);
        if (hasFocus) {
          widget.onFocused();
          // 焦点进入卡片时自动滚入可视区域；已可见时是 no-op，无外层 Scrollable 时静默忽略
          try {
            Scrollable.ensureVisible(
              context,
              duration: const Duration(milliseconds: 300),
              alignment: 0.3,
            );
          } catch (_) {}
        }
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        // OK / Enter → 触发选中
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          widget.onSelected();
          return KeyEventResult.handled;
        }
        // 向上：rail 有「更多」按钮时优先跳它（语义上属于同一 rail）；否则
        // 默认几何上行；再兜底 Banner 播放按钮
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          if (widget.onUpEdge != null) {
            widget.onUpEdge!();
            return KeyEventResult.handled;
          }
          final moved =
              FocusScope.of(context).focusInDirection(TraversalDirection.up);
          if (moved) {
            // 几何上行若落到 Banner，顺手把 Banner 拉回视口
            final anchor = HomeFocusAnchors.of(context);
            if (anchor != null && anchor.bannerPlay.hasPrimaryFocus) {
              anchor.ensureBannerVisible();
            }
            return KeyEventResult.handled;
          }
          final anchor = HomeFocusAnchors.of(context);
          if (anchor != null) {
            anchor.bannerPlay.requestFocus();
            anchor.ensureBannerVisible();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }
        // 向右：默认先试；rail 尾端找不到候选时兜底到「更多」按钮（如果有）
        if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
            widget.onRightEdge != null) {
          final moved =
              FocusScope.of(context).focusInDirection(TraversalDirection.right);
          if (moved) return KeyEventResult.handled;
          widget.onRightEdge!();
          return KeyEventResult.handled;
        }
        // 向下、向左：完全交给 Flutter 默认方向焦点策略
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onSelected,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = PlatformService.isMobile;
              final defaultW = widget.landscape
                  ? (isMobile ? 160.0 : AppSpacing.cardWidthLandscape)
                  : (isMobile ? 120.0 : AppSpacing.cardWidth);
              final defaultH = widget.landscape
                  ? (isMobile ? 100.0 : AppSpacing.cardHeightLandscape)
                  : (isMobile ? 180.0 : AppSpacing.cardHeight);
              final w = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : defaultW;
              final h = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : defaultH;

              // 元数据文本
              final metaText = [
                if (widget.video.year?.isNotEmpty == true) widget.video.year,
                if (widget.video.category?.isNotEmpty == true)
                  widget.video.category,
              ].whereType<String>().join(' · ');

              return AnimatedContainer(
                duration: Duration(milliseconds: _highlighted ? 150 : 100),
                curve: _highlighted ? Curves.easeOut : Curves.easeIn,
                width: w,
                height: h,
                transform: Matrix4.diagonal3Values(
                  _highlighted ? 1.05 : 1.0,
                  _highlighted ? 1.05 : 1.0,
                  1.0,
                ),
                transformAlignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: AppRadius.cardBorder,
                  border: _focused
                      ? Border.all(color: AppColors.netflixRed, width: 2)
                      : null,
                  boxShadow: _highlighted
                      ? [
                          BoxShadow(
                            color: _focused
                                ? AppColors.netflixRed.withAlpha(80)
                                : Colors.black.withAlpha(160),
                            blurRadius: 16,
                            spreadRadius: 2,
                          )
                        ]
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: AppRadius.cardBorder,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 封面图（memCacheWidth 下采样，竖版 320px / 横版 426px）
                      ResolvableCover(
                        directUrl: widget.video.cover,
                        title: widget.video.title,
                        year: widget.video.year,
                        seed: '${widget.video.siteKey}:${widget.video.id}',
                        fit: BoxFit.cover,
                        memCacheWidth: widget.landscape ? 426 : 320,
                      ),
                      // 底部渐变（始终显示，确保标题可读）
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: h * 0.5,
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Color(0xDD000000),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 标题（始终可见）
                      Positioned(
                        bottom: 8,
                        left: 8,
                        right: 8,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.video.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.title.copyWith(
                                fontSize: 13,
                                height: 1.3,
                              ),
                            ),
                            // 元数据（hover/focus 时显示）
                            AnimatedSize(
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOut,
                              alignment: Alignment.topLeft,
                              child: _highlighted && metaText.isNotEmpty
                                  ? Padding(
                                      padding: const EdgeInsets.only(top: 3),
                                      child: Text(
                                        metaText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTypography.caption.copyWith(
                                          fontSize: 11,
                                          color: AppColors.secondaryText,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                      // 备注标签（右上角，始终可见）
                      if (widget.video.remarks?.isNotEmpty == true)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.xs,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.deepBlack.withAlpha(178),
                              borderRadius: AppRadius.tagBorder,
                            ),
                            child: Text(
                              widget.video.remarks!,
                              style:
                                  AppTypography.caption.copyWith(fontSize: 11),
                            ),
                          ),
                        ),
                      // 继续观看进度条
                      if (widget.history != null)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: widget.history!.progress,
                            minHeight: 3,
                            backgroundColor: AppColors.hintText.withAlpha(77),
                            valueColor: const AlwaysStoppedAnimation(
                                AppColors.netflixRed),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
