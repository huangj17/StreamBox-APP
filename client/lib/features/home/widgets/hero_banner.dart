import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/platform/platform_service.dart';
import '../../../data/models/video_item.dart';
import '../../../widgets/resolvable_cover.dart';
import 'home_focus_anchors.dart';

/// Hero 轮播 Banner
/// 高度 540dp，6 秒自动轮播，800ms crossfade
/// 支持左右箭头、指示器点击、滑动手势手动切换
class HeroBanner extends StatefulWidget {
  final List<VideoItem> items;
  final Duration autoPlayInterval;
  final void Function(VideoItem item) onItemFocused;
  /// 「详情」按钮 / banner 整体点击 → 打开详情页
  final void Function(VideoItem item) onItemSelected;
  /// 「播放」按钮 → 直接进播放器（异步：fetch 详情拿到第一集再 push）
  final Future<void> Function(VideoItem item) onItemPlay;
  /// TV 端首页默认焦点设在「播放」按钮；桌面/手机保持 false。
  final bool autofocus;
  /// 首页注入的「播放」按钮 FocusNode，供下方 VideoCard 作上键兜底的锚点。
  final FocusNode? playFocusNode;

  const HeroBanner({
    super.key,
    required this.items,
    this.autoPlayInterval = const Duration(seconds: 6),
    required this.onItemFocused,
    required this.onItemSelected,
    required this.onItemPlay,
    this.autofocus = false,
    this.playFocusNode,
  });

  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  int _currentIndex = 0;
  Timer? _timer;
  bool _paused = false;
  bool _isHovering = false;
  bool _isLoadingPlay = false;
  bool _playFocused = false;
  bool _detailFocused = false;

  Future<void> _handlePlay(VideoItem item) async {
    if (_isLoadingPlay) return;
    setState(() => _isLoadingPlay = true);
    _paused = true;
    try {
      await widget.onItemPlay(item);
    } finally {
      if (mounted) {
        setState(() => _isLoadingPlay = false);
        _paused = false;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startAutoPlay() {
    _timer?.cancel();
    if (widget.items.length <= 1) return;
    _timer = Timer.periodic(widget.autoPlayInterval, (_) {
      if (!_paused && mounted) {
        _goTo((_currentIndex + 1) % widget.items.length);
      }
    });
  }

  /// 跳转到指定 index 并重置自动轮播计时器
  void _goTo(int index) {
    if (!mounted || index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
    });
    widget.onItemFocused(widget.items[_currentIndex]);
    _resetAutoPlay();
  }

  void _goNext() {
    _goTo((_currentIndex + 1) % widget.items.length);
  }

  void _goPrev() {
    _goTo((_currentIndex - 1 + widget.items.length) % widget.items.length);
  }

  static bool _isActivateKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.gameButtonA;

  /// 播放 / 详情按钮键处理：
  /// - Enter/OK → 调 [onActivate]（onKeyEvent 挂在主焦点节点上，按钮自身
  ///   不再消费 Activate，必须显式处理）
  /// - 上 → 跳到顶栏首项（默认方向焦点策略常因几何距离过远找不到顶栏）
  /// - 左/右 → 交给默认焦点流，走到箭头按钮上再 Enter 切换 banner
  KeyEventResult _handleBannerButtonKey(
    KeyEvent event,
    VoidCallback onActivate,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_isActivateKey(event.logicalKey)) {
      onActivate();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final anchor = HomeFocusAnchors.of(context);
      if (anchor != null) {
        anchor.topNavFirst.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  /// 重置自动轮播计时器（手动切换后重新计时）
  void _resetAutoPlay() {
    _startAutoPlay();
  }

  /// 可聚焦的 Banner 按钮封装
  ///
  /// 外层 `Focus` 本身就是主焦点节点（带 autofocus + 外部 focusNode），
  /// 红色描边靠 `focused` 标志显式绘制——不依赖 ElevatedButton 的内部高亮，
  /// 在任何主题/平台下都能明确看到选中态。
  /// Enter/OK 由 `onActivate` 显式触发，不走按钮自身 Activate，避免
  /// 「焦点在外层但按钮内层不响应」的问题。
  Widget _focusableBannerButton({
    FocusNode? focusNode,
    bool autofocus = false,
    required bool focused,
    required ValueChanged<bool> onFocusChanged,
    required VoidCallback onActivate,
    required Widget child,
  }) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onFocusChange: onFocusChanged,
      onKeyEvent: (node, event) => _handleBannerButtonKey(event, onActivate),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: focused ? AppColors.netflixRed : Colors.transparent,
            width: 2,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: AppColors.netflixRed.withAlpha(100),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return SizedBox(
        height: PlatformService.isMobile ? 320.0 : AppSpacing.heroBannerHeight,
        child: Container(color: AppColors.cardBackground),
      );
    }

    final item = widget.items[_currentIndex];
    final isMobile = PlatformService.isMobile;
    final canSwipe = widget.items.length > 1;
    final showArrows = canSwipe && !isMobile;
    final bannerHeight = isMobile ? 320.0 : AppSpacing.heroBannerHeight;

    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        child: GestureDetector(
          onHorizontalDragEnd: canSwipe
              ? (details) {
                  if (details.primaryVelocity == null) return;
                  if (details.primaryVelocity! < -100) {
                    _goNext(); // 左滑 → 下一条
                  } else if (details.primaryVelocity! > 100) {
                    _goPrev(); // 右滑 → 上一条
                  }
                }
              : null,
          child: SizedBox(
            height: bannerHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 背景图 crossfade
                // 横版 backdrop 全覆盖；竖版海报靠右显示，左侧留给文字+渐变
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 800),
                  child: _BannerImage(
                    key: ValueKey(item.id),
                    imageUrl: item.backdrop ?? item.cover,
                    hasBackdrop: item.backdrop != null,
                    title: item.title,
                    year: item.year,
                    seed: '${item.siteKey}:${item.id}',
                  ),
                ),

                // 左侧渐变
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: AppColors.heroLeftGradient,
                      stops: [0.5, 1.0],
                    ),
                  ),
                ),

                // 底部渐变
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: AppColors.heroBottomGradient,
                      stops: [0.6, 1.0],
                    ),
                  ),
                ),

                // 内容区（左下角）
                Positioned(
                  left: isMobile ? AppSpacing.lg : AppSpacing.xl + 56,
                  bottom: isMobile ? AppSpacing.lg : AppSpacing.xxl,
                  right: isMobile
                      ? AppSpacing.lg
                      : MediaQuery.of(context).size.width * 0.5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题
                      Text(
                        item.title,
                        style: isMobile
                            ? AppTypography.headline2.copyWith(fontSize: 22)
                            : AppTypography.display,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      // 元数据
                      Text(
                        [
                          if (item.year?.isNotEmpty == true) item.year,
                          if (item.category?.isNotEmpty == true) item.category,
                          if (item.remarks?.isNotEmpty == true) item.remarks,
                        ].whereType<String>().join(' · '),
                        style: isMobile
                            ? AppTypography.caption.copyWith(fontSize: 12)
                            : AppTypography.caption,
                        maxLines: 1,
                      ),
                      // 简介（手机端不显示）
                      if (!isMobile && item.description?.isNotEmpty == true) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          item.description!,
                          style: AppTypography.body,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                      // 操作按钮
                      Wrap(
                        spacing: isMobile ? AppSpacing.sm : AppSpacing.md,
                        runSpacing: AppSpacing.sm,
                        children: [
                          _focusableBannerButton(
                            focusNode: widget.playFocusNode,
                            autofocus: widget.autofocus && !_isLoadingPlay,
                            focused: _playFocused,
                            onFocusChanged: (hasFocus) {
                              setState(() => _playFocused = hasFocus);
                              if (!_isLoadingPlay) _paused = hasFocus;
                              // 注意：不要在这里 ensureVisible。路由 pop 回 Home
                              // 时按钮会重新拿到 primary focus，会被误触发成滚到顶。
                              // 滚动由 VideoCard / 「更多」按钮在显式 ↑ 时调。
                            },
                            onActivate: () {
                              if (!_isLoadingPlay) _handlePlay(item);
                            },
                            child: ElevatedButton.icon(
                              onPressed: _isLoadingPlay
                                  ? null
                                  : () => _handlePlay(item),
                              icon: _isLoadingPlay
                                  ? SizedBox(
                                      width: isMobile ? 14 : 18,
                                      height: isMobile ? 14 : 18,
                                      child: const CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.deepBlack,
                                      ),
                                    )
                                  : Icon(Icons.play_arrow, size: isMobile ? 18 : 24),
                              label: Text('播放', style: TextStyle(fontSize: isMobile ? 13 : null)),
                              style: isMobile
                                  ? ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    )
                                  : null,
                            ),
                          ),
                          _focusableBannerButton(
                            focused: _detailFocused,
                            onFocusChanged: (hasFocus) {
                              setState(() => _detailFocused = hasFocus);
                              _paused = hasFocus;
                              // 同 play 按钮：不在这里 ensureVisible。
                            },
                            onActivate: () => widget.onItemSelected(item),
                            child: ElevatedButton.icon(
                              onPressed: () => widget.onItemSelected(item),
                              icon: Icon(Icons.info_outline, size: isMobile ? 18 : 24),
                              label: Text('详情', style: TextStyle(fontSize: isMobile ? 13 : null)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xB36D6D6E),
                                foregroundColor: AppColors.primaryText,
                                padding: isMobile
                                    ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8)
                                    : null,
                                minimumSize: isMobile ? Size.zero : null,
                                tapTargetSize: isMobile ? MaterialTapTargetSize.shrinkWrap : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 左箭头：鼠标 hover 时淡入；在焦点系统（TV/桌面）下常驻
                // 焦点时可用 Enter 触发切换
                if (showArrows)
                  Positioned(
                    left: AppSpacing.md,
                    top: 0,
                    bottom: 0,
                    child: _ArrowButton(
                      icon: Icons.chevron_left,
                      alwaysShow: PlatformService.needsFocusSystem,
                      visibleOnHover: _isHovering,
                      onPressed: _goPrev,
                      onHoverChanged: (hovering) {
                        _paused = hovering;
                      },
                      onFocusChanged: (hasFocus) {
                        _paused = hasFocus;
                      },
                    ),
                  ),

                // 右箭头
                if (showArrows)
                  Positioned(
                    right: AppSpacing.md,
                    top: 0,
                    bottom: 0,
                    child: _ArrowButton(
                      icon: Icons.chevron_right,
                      alwaysShow: PlatformService.needsFocusSystem,
                      visibleOnHover: _isHovering,
                      onPressed: _goNext,
                      onHoverChanged: (hovering) {
                        _paused = hovering;
                      },
                      onFocusChanged: (hasFocus) {
                        _paused = hasFocus;
                      },
                    ),
                  ),

                // 页面指示器（可点击）
                if (canSwipe)
                  Positioned(
                    right: isMobile ? AppSpacing.lg : AppSpacing.xl,
                    bottom: isMobile ? AppSpacing.lg : AppSpacing.xxl,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(widget.items.length, (i) {
                        final isActive = i == _currentIndex;
                        return GestureDetector(
                          onTap: () => _goTo(i),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 8,
                              ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                width: isActive ? 24 : 8,
                                height: 4,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(2),
                                  color: isActive
                                      ? AppColors.primaryText
                                      : AppColors.hintText,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner 左右切换箭头按钮
///
/// - `alwaysShow`：TV / 桌面键盘模式常驻显示（焦点系统需要能看见才能选中）
/// - `visibleOnHover`：鼠标 hover 时淡入（不常驻时的原始行为）
/// - 可聚焦：Tab / 方向键能走到箭头上，Enter 切换 banner
class _ArrowButton extends StatefulWidget {
  final IconData icon;
  final bool alwaysShow;
  final bool visibleOnHover;
  final VoidCallback onPressed;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<bool>? onFocusChanged;

  const _ArrowButton({
    required this.icon,
    required this.alwaysShow,
    required this.visibleOnHover,
    required this.onPressed,
    required this.onHoverChanged,
    this.onFocusChanged,
  });

  @override
  State<_ArrowButton> createState() => _ArrowButtonState();
}

class _ArrowButtonState extends State<_ArrowButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _focused || _hovered;
    final visible = widget.alwaysShow || widget.visibleOnHover || _focused;
    return Center(
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !visible,
          child: Focus(
            onFocusChange: (hasFocus) {
              setState(() => _focused = hasFocus);
              widget.onFocusChanged?.call(hasFocus);
            },
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.select ||
                      event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
                widget.onPressed();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: MouseRegion(
              onEnter: (_) {
                setState(() => _hovered = true);
                widget.onHoverChanged(true);
              },
              onExit: (_) {
                setState(() => _hovered = false);
                widget.onHoverChanged(false);
              },
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: widget.onPressed,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: highlighted ? Colors.black87 : Colors.black54,
                    border: _focused
                        ? Border.all(
                            color: AppColors.netflixRed,
                            width: 2,
                          )
                        : null,
                    boxShadow: _focused
                        ? [
                            BoxShadow(
                              color: AppColors.netflixRed.withAlpha(100),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(widget.icon, color: Colors.white, size: 24),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner 背景图：横版 backdrop 全覆盖，竖版海报用模糊底+右侧清晰图
class _BannerImage extends StatelessWidget {
  final String imageUrl;
  final bool hasBackdrop;
  final String title;
  final String? year;
  final String seed;

  const _BannerImage({
    super.key,
    required this.imageUrl,
    required this.hasBackdrop,
    required this.title,
    required this.year,
    required this.seed,
  });

  @override
  Widget build(BuildContext context) {
    // 有横版 backdrop 时直接全覆盖
    if (hasBackdrop) {
      return ResolvableCover(
        directUrl: imageUrl,
        title: title,
        year: year,
        seed: seed,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        memCacheWidth: 1920,
        letterScale: 0.3,
      );
    }

    // 竖版海报：模糊放大背景 + 右侧清晰海报。
    // 模糊层用 ImageFiltered 直接对海报做滤镜（不用 BackdropFilter，避免
    // 采样到 layer 上的其他内容导致串图）。右侧清晰海报也走 ResolvableCover，
    // 失败时不显示（靠模糊层字母海报打底）。
    return Stack(
      fit: StackFit.expand,
      children: [
        ResolvableCover(
          directUrl: imageUrl,
          title: title,
          year: year,
          seed: seed,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          memCacheWidth: 512,
          letterScale: 0.3,
          imageBuilder: (context, imageProvider) => ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Image(
              image: imageProvider,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              color: Colors.black.withAlpha(80),
              colorBlendMode: BlendMode.darken,
            ),
          ),
        ),
        Positioned(
          right:
              PlatformService.isMobile ? AppSpacing.lg : AppSpacing.xl + 56,
          top: AppSpacing.xl,
          bottom: AppSpacing.xl,
          // AspectRatio 强制 2:3 海报区，避免 fallback / placeholder 为 0×0
          // 时右侧主图被锁成 0 宽度
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: ResolvableCover(
              directUrl: imageUrl,
              title: title,
              year: year,
              seed: seed,
              fit: BoxFit.cover,
              memCacheWidth: 800,
              fallback: const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}
