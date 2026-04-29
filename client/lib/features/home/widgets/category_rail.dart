import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/platform/platform_service.dart';
import '../../../data/models/category.dart';
import '../../../data/models/video_item.dart';
import '../../../data/models/watch_history.dart';
import '../../../widgets/skeleton_card.dart';
import '../../../widgets/error_rail.dart';
import 'home_focus_anchors.dart';
import 'video_card.dart';

/// 分类内容行
/// 标题 + 水平滚动卡片列表
class CategoryRail extends StatefulWidget {
  final Category category;
  final AsyncValue<List<VideoItem>> items;
  final void Function(VideoItem item) onItemSelected;
  final void Function(VideoItem item)? onItemFocused;
  final VoidCallback? onRetry;
  final VoidCallback? onViewMore;
  final bool showProgress;
  final List<WatchHistory> histories;

  const CategoryRail({
    super.key,
    required this.category,
    required this.items,
    required this.onItemSelected,
    this.onItemFocused,
    this.onRetry,
    this.onViewMore,
    this.showProgress = false,
    this.histories = const [],
  });

  @override
  State<CategoryRail> createState() => _CategoryRailState();
}

class _CategoryRailState extends State<CategoryRail> {
  bool _rowFocused = false;
  // 「更多」按钮的 FocusNode——提供给 rail 尾端卡片按 → 时作为兜底锚点。
  // 本地持有即可，不跨 rail 共享。
  FocusNode? _viewMoreFocus;

  @override
  void initState() {
    super.initState();
    if (widget.onViewMore != null) {
      _viewMoreFocus = FocusNode(debugLabel: 'view-more-${widget.category.id}');
    }
  }

  @override
  void didUpdateWidget(CategoryRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final needs = widget.onViewMore != null;
    if (needs && _viewMoreFocus == null) {
      _viewMoreFocus =
          FocusNode(debugLabel: 'view-more-${widget.category.id}');
    } else if (!needs && _viewMoreFocus != null) {
      _viewMoreFocus!.dispose();
      _viewMoreFocus = null;
    }
  }

  @override
  void dispose() {
    _viewMoreFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 数据已加载但为空时完全隐藏（含标题），避免显示空白行
    if (widget.items.valueOrNull?.isEmpty == true) {
      return const SizedBox.shrink();
    }

    final isMobile = PlatformService.isMobile;
    final hPadding = isMobile ? AppSpacing.md : AppSpacing.xl;

    return Focus(
      skipTraversal: true,
      onFocusChange: (hasFocus) => setState(() => _rowFocused = hasFocus),
      child: Padding(
        padding: EdgeInsets.only(bottom: isMobile ? AppSpacing.md : AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 行标题 + 查看更多
            Padding(
              padding: EdgeInsets.only(
                left: hPadding,
                right: hPadding,
                bottom: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    transform: _rowFocused
                        ? (Matrix4.diagonal3Values(1.05, 1.05, 1.0)
                          ..setTranslationRaw(-4.0, 0, 0))
                        : Matrix4.identity(),
                    transformAlignment: Alignment.centerLeft,
                    child: Text(
                      widget.category.name,
                      style: isMobile
                          ? AppTypography.headline2.copyWith(fontSize: 18)
                          : AppTypography.headline2,
                    ),
                  ),
                  const Spacer(),
                  if (widget.onViewMore != null)
                    _ViewMoreButton(
                      focusNode: _viewMoreFocus,
                      onTap: widget.onViewMore!,
                    ),
                ],
              ),
            ),
            // 内容区
            SizedBox(
              height: (widget.showProgress
                      ? (isMobile ? 100.0 : AppSpacing.cardHeightLandscape)
                      : (isMobile ? 180.0 : AppSpacing.cardHeight)) +
                  (isMobile ? 30 : 40),
              child: widget.items.when(
                loading: () => _buildSkeletonList(),
                error: (e, _) => ErrorRail(
                  message: '加载失败，按 OK 重试',
                  onRetry: widget.onRetry,
                ),
                data: (list) {
                  if (list.isEmpty) return const SizedBox.shrink();
                  return _buildCardList(list);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeletonList() {
    final isMobile = PlatformService.isMobile;
    final cardW = widget.showProgress
        ? (isMobile ? 160.0 : AppSpacing.cardWidthLandscape)
        : (isMobile ? 120.0 : AppSpacing.cardWidth);
    final cardH = widget.showProgress
        ? (isMobile ? 100.0 : AppSpacing.cardHeightLandscape)
        : (isMobile ? 180.0 : AppSpacing.cardHeight);
    final hPadding = isMobile ? AppSpacing.md : AppSpacing.xl;

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: hPadding),
      itemCount: 6,
      separatorBuilder: (_, _) => SizedBox(width: isMobile ? AppSpacing.sm : AppSpacing.md),
      itemBuilder: (_, _) => SkeletonCard(
        width: cardW,
        height: cardH,
      ),
    );
  }

  Widget _buildCardList(List<VideoItem> items) {
    final isMobile = PlatformService.isMobile;
    final edgePadding = isMobile ? AppSpacing.md + 4.0 : AppSpacing.xl + 8.0;

    return ListView.separated(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      cacheExtent: 300,
      padding: EdgeInsets.symmetric(
        horizontal: edgePadding,
        vertical: isMobile ? 10 : 20,
      ),
      itemCount: items.length,
      separatorBuilder: (_, _) => SizedBox(width: isMobile ? AppSpacing.sm : AppSpacing.md),
      itemBuilder: (context, index) {
        final video = items[index];
        // 查找对应的历史记录
        final history = widget.histories
            .where(
                (h) => h.videoId == video.id && h.siteKey == video.siteKey)
            .firstOrNull;

        return VideoCard(
          video: video,
          history: history,
          landscape: widget.showProgress,
          onSelected: () => widget.onItemSelected(video),
          onFocused: () => widget.onItemFocused?.call(video),
          // rail 尾端卡片按 → 时兜底跳到本 rail「更多」按钮；非末尾卡片
          // 默认方向焦点先聚下一张卡，这个回调根本不会触发
          onRightEdge: _viewMoreFocus != null
              ? () => _viewMoreFocus!.requestFocus()
              : null,
          // 任意卡片按 ↑ 直接跳本 rail「更多」按钮（无「更多」时走默认几何 + Banner 兜底）
          onUpEdge: _viewMoreFocus != null
              ? () => _viewMoreFocus!.requestFocus()
              : null,
        );
      },
    );
  }
}

/// 可聚焦的"更多 >"按钮
class _ViewMoreButton extends StatefulWidget {
  final VoidCallback onTap;
  final FocusNode? focusNode;

  const _ViewMoreButton({required this.onTap, this.focusNode});

  @override
  State<_ViewMoreButton> createState() => _ViewMoreButtonState();
}

class _ViewMoreButtonState extends State<_ViewMoreButton> {
  bool _focused = false;
  bool _hovered = false;

  bool get _highlighted => _focused || _hovered;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (hasFocus) {
        setState(() => _focused = hasFocus);
        if (hasFocus) {
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
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        // ↑：优先几何上行；失败则兜底 Banner 播放按钮（与 VideoCard 对齐）
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          final moved =
              FocusScope.of(context).focusInDirection(TraversalDirection.up);
          if (moved) {
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
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: _highlighted
                  ? AppColors.surface
                  : Colors.transparent,
              border: _focused
                  ? Border.all(color: AppColors.netflixRed, width: 1)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '更多',
                  style: AppTypography.caption.copyWith(
                    color: _highlighted
                        ? AppColors.primaryText
                        : AppColors.secondaryText,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right,
                    size: 16,
                    color: _highlighted
                        ? AppColors.primaryText
                        : AppColors.secondaryText),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
