import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/util/site_navigation.dart';
import '../../data/models/site.dart';
import '../../data/models/category.dart';
import '../../data/models/video_item.dart';
import '../../data/models/watch_history.dart';
import '../../widgets/side_nav_bar.dart';
import '../../widgets/skeleton_card.dart';
import '../../widgets/tv_focus.dart';
import '../../core/platform/platform_service.dart';
import 'providers/categories_provider.dart';
import '../source/providers/source_provider.dart';
import '../detail/providers/detail_provider.dart';
import 'widgets/hero_banner.dart';
import 'widgets/category_rail.dart';
import 'widgets/home_focus_anchors.dart';

/// 首页
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _scrollController = ScrollController();
  // 焦点锚点：Banner Play 是内容入口；navFirst 是 SideNav 首项；
  // errorRetry 是错误态「重试」按钮（仅错误态被 widget attach）
  final _bannerPlayFocus = FocusNode(debugLabel: 'banner-play');
  final _sideNavFirstFocus = FocusNode(debugLabel: 'side-nav-home');
  final _errorRetryFocus = FocusNode(debugLabel: 'error-retry');
  bool _restoring = true; // 启动时恢复状态中，避免闪现输入界面

  @override
  void initState() {
    super.initState();
    // 从 Hive 恢复持久化状态
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreFromStorage());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _bannerPlayFocus.dispose();
    _sideNavFirstFocus.dispose();
    _errorRetryFocus.dispose();
    super.dispose();
  }

  /// 把首页滚回最顶（Banner 回到视口顶部）。供 VideoCard / 「更多」按钮在
  /// 用户主动上行到 Banner 时调用。
  void _ensureBannerVisible() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.offset <= 0) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 从 Hive 恢复上次的配置源和 sites 状态
  /// 首次启动时自动写入默认片源
  Future<void> _restoreFromStorage() async {
    if (!mounted) return;
    final storage = ref.read(sourceStorageProvider);

    // 首次启动：写入默认片源并选中第一个
    await storage.initDefaultsIfEmpty();

    final savedUrls = storage.getAll();
    final selectedUrl = storage.getSelected();

    if (savedUrls.isNotEmpty) {
      ref.read(savedSourceUrlsProvider.notifier).state = savedUrls;
    }
    if (selectedUrl != null) {
      ref.read(selectedSourceUrlProvider.notifier).state = selectedUrl;
      try {
        // 检测是否多仓，恢复上次选中的仓库
        final warehouses = await ref.read(warehouseListProvider.future);
        if (warehouses.isNotEmpty) {
          final lastWh = storage.getSelectedWarehouse(selectedUrl);
          if (lastWh != null && warehouses.any((w) => w.url == lastWh)) {
            ref.read(selectedWarehouseUrlProvider.notifier).state = lastWh;
          }
        }
        await ref.read(sourceConfigProvider.future);
        if (mounted) {
          syncSitesToHome(ref);
          // Bridge 源：恢复上次选中的插件（全部 sites → 单个 plugin site）
          if (selectedUrl.contains(':9978')) {
            final pluginKey = storage.getSelectedBridgePlugin(selectedUrl);
            if (pluginKey != null) {
              final allSites = ref.read(sitesProvider);
              final matched = allSites
                  .where((s) => s.key == pluginKey)
                  .toList();
              if (matched.isNotEmpty) {
                ref.read(sitesProvider.notifier).state = matched;
              }
            }
          }
        }
      } catch (_) {
        // 解析失败时静默忽略，用户可在管理页重试
      }
    }

    if (mounted) setState(() => _restoring = false);
  }

  void _navigateToDetail(VideoItem video) {
    navigateToVideoDetail(
      context,
      ref,
      siteKey: video.siteKey,
      videoId: video.id,
      title: video.title,
      initialGroupIndex: video.historyGroupIndex,
      initialEpisodeIndex: video.historyEpisodeIndex,
      initialPositionMs: video.historyPositionMs,
    );
  }

  /// Banner「播放」按钮：fetch 详情拿到第一集 → 直接进播放器
  /// 找不到可播剧集时降级到详情页
  Future<void> _playFromBanner(VideoItem video) async {
    final sites = ref.read(sitesProvider);
    final matched = sites.where((s) => s.key == video.siteKey).toList();
    if (matched.isEmpty) {
      // 源已下架 → 走通用反馈路径（SnackBar + 去搜索）
      _navigateToDetail(video);
      return;
    }
    final site = matched.first;

    try {
      final detail = await ref.read(
        videoDetailProvider((site: site, videoId: video.id)).future,
      );
      if (!mounted) return;
      final groups = detail?.episodeGroups ?? const [];
      // 找到第一个有可播 URL 的剧集
      int gi = -1, ei = -1;
      for (var i = 0; i < groups.length; i++) {
        for (var j = 0; j < groups[i].length; j++) {
          if (groups[i][j].url.isNotEmpty) {
            gi = i;
            ei = j;
            break;
          }
        }
        if (gi >= 0) break;
      }
      if (detail == null || gi < 0) {
        _navigateToDetail(video);
        return;
      }

      // 检查历史记录续播
      final histories = ref.read(historyStorageProvider).getAllUnfiltered();
      int positionMs = 0;
      final hist = histories.where(
        (h) => h.videoId == detail.vodId.toString() && h.siteKey == site.key,
      );
      if (hist.isNotEmpty) {
        final h = hist.first;
        if (h.groupIndex < groups.length &&
            h.episodeIndex < groups[h.groupIndex].length &&
            groups[h.groupIndex][h.episodeIndex].url.isNotEmpty) {
          gi = h.groupIndex;
          ei = h.episodeIndex;
          positionMs = h.positionMs;
        }
      }

      await context.push(
        '/player',
        extra: {
          'videoId': detail.vodId.toString(),
          'site': site,
          'videoTitle': detail.vodName,
          'cover': detail.vodPic,
          'episodeGroups': groups,
          'sourceNames': detail.sourceNames,
          'initialGroupIndex': gi,
          'initialEpisodeIndex': ei,
          'initialPositionMs': positionMs,
          'category': detail.vodClass,
        },
      );
    } catch (_) {
      if (mounted) _navigateToDetail(video);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sites = ref.watch(sitesProvider);
    final categories = ref.watch(categoriesProvider);
    final bannerItems = ref.watch(bannerItemsProvider);
    final watchHistory = ref.watch(watchHistoryProvider);

    final isMobile = PlatformService.isMobile;

    final mainContent = _restoring
        ? _buildLoadingState()
        : sites.isEmpty
        ? _buildSourceInput()
        : _buildMainContent(categories, bannerItems, watchHistory);

    return HomeFocusAnchors(
      bannerPlay: _bannerPlayFocus,
      navFirst: _sideNavFirstFocus,
      errorRetry: _errorRetryFocus,
      ensureBannerVisible: _ensureBannerVisible,
      child: Scaffold(
        body: SafeArea(
          top: isMobile,
          bottom: false,
          child: isMobile
              ? mainContent
              // Stack：SideNav 收起 80dp 与 content padding 对齐；展开时
              // 浮在内容之上覆盖到 240dp，不推动内容重新布局，避免视觉抖动
              : Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        left: AppSpacing.sideNavCollapsedWidth,
                      ),
                      child: mainContent,
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      child: SideNavBar(
                        selectedIndex: 0,
                        firstItemFocusNode: _sideNavFirstFocus,
                        onItemSelected: (index) {
                          if (index == 2) context.push('/search');
                          if (index == 3) context.push('/settings');
                        },
                        onExitToContent: () {
                          // 错误态优先聚 Retry（避免焦点掉进未渲染的 Banner）
                          if (_errorRetryFocus.context != null &&
                              _errorRetryFocus.canRequestFocus) {
                            _errorRetryFocus.requestFocus();
                            return;
                          }
                          _bannerPlayFocus.requestFocus();
                        },
                      ),
                    ),
                  ],
                ),
        ),
        // 底部导航栏（手机端）
        bottomNavigationBar: isMobile
            ? BottomNavigationBar(
                currentIndex: 0,
                onTap: (index) {
                  if (index == 1) context.push('/search');
                  if (index == 2) context.push('/settings');
                },
                type: BottomNavigationBarType.fixed,
                backgroundColor: AppColors.deepBlack,
                selectedItemColor: AppColors.netflixRed,
                unselectedItemColor: AppColors.secondaryText,
                selectedFontSize: 12,
                unselectedFontSize: 12,
                items: const [
                  BottomNavigationBarItem(icon: Icon(Icons.home), label: '首页'),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.search),
                    label: '搜索',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings),
                    label: '设置',
                  ),
                ],
              )
            : null,
      ),
    );
  }

  /// 未配置源时显示空态：直接引导去设置添加源（替代原 TextField，TV 焦点路由更顺）
  /// 复用 [_errorRetryFocus] 锚点，让 SideNav→ 退出能落到这里
  Widget _buildSourceInput() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'StreamBox',
              style: AppTypography.display.copyWith(
                color: AppColors.netflixRed,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Icon(
              Icons.video_library_outlined,
              color: AppColors.hintText,
              size: 56,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('还没有配置片源', style: AppTypography.body),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '前往设置 → 配置源管理添加源',
              style: AppTypography.caption.copyWith(color: AppColors.hintText),
            ),
            const SizedBox(height: AppSpacing.xl),
            _ErrorActionButton(
              label: '去添加配置源',
              primary: true,
              autofocus: true,
              focusNode: _errorRetryFocus,
              onActivate: () => context.push('/source'),
              onLeftEscape: PlatformService.needsFocusSystem
                  ? () => _sideNavFirstFocus.requestFocus()
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 有内容时显示 Netflix 风格首页
  Widget _buildMainContent(
    AsyncValue<List<Category>> categories,
    AsyncValue<List<VideoItem>> bannerItems,
    AsyncValue<List<WatchHistory>> watchHistory,
  ) {
    return categories.when(
      loading: () => _buildLoadingState(),
      error: (e, _) => _buildErrorState(e),
      data: (categoryList) {
        final dynamicCategories = categoryList
            .where((c) => c.type == CategoryType.dynamic)
            .toList();

        if (dynamicCategories.isEmpty) {
          return _buildErrorState('暂无内容，请检查配置源');
        }

        final histories = watchHistory.valueOrNull ?? [];

        return CustomScrollView(
          controller: _scrollController,
          // scrollCacheExtent 覆盖多条 rail，方向键焦点跨 rail 导航时有足够候选
          scrollCacheExtent: const ScrollCacheExtent.pixels(1500),
          slivers: [
            // Hero Banner
            SliverToBoxAdapter(
              child: bannerItems.when(
                data: (items) => items.isEmpty
                    ? const SkeletonBanner()
                    : HeroBanner(
                        items: items,
                        // TV / 桌面键盘模式下默认焦点放在 Banner 播放按钮，
                        // 否则初次按下键会从空焦点按几何距离跳过 Banner 直达 Rail
                        autofocus: PlatformService.needsFocusSystem,
                        playFocusNode: _bannerPlayFocus,
                        onItemFocused: (_) {},
                        onItemSelected: _navigateToDetail,
                        onItemPlay: _playFromBanner,
                      ),
                loading: () => const SkeletonBanner(),
                error: (_, _) => const SkeletonBanner(),
              ),
            ),

            // Banner 与内容行之间留白
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),

            // 继续观看行（有历史时才显示）
            if (histories.isNotEmpty)
              SliverToBoxAdapter(
                child: CategoryRail(
                  category: FixedCategories.watchHistory,
                  items: AsyncValue.data(
                    histories.map(VideoItem.fromHistory).toList(),
                  ),
                  showProgress: true,
                  histories: histories,
                  isFirstRail: true,
                  onItemSelected: _navigateToDetail,
                  onViewMore: () => context.push('/history'),
                ),
              ),

            // 动态分类行
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final cat = dynamicCategories[index];
                // 没有「继续观看」时，dynamicCategories[0] 是首条 rail
                final isFirst = histories.isEmpty && index == 0;
                return _CategoryRailWrapper(
                  category: cat,
                  isFirstRail: isFirst,
                  onItemSelected: _navigateToDetail,
                );
              }, childCount: dynamicCategories.length),
            ),

            // 底部留白
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
          ],
        );
      },
    );
  }

  Widget _buildLoadingState() {
    return ListView(
      children: [
        const SkeletonBanner(),
        const SizedBox(height: AppSpacing.lg),
        const SkeletonRail(),
        const SkeletonRail(),
        const SkeletonRail(),
      ],
    );
  }

  Widget _buildErrorState(Object error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppColors.hintText, size: 48),
          const SizedBox(height: AppSpacing.md),
          Text(
            '$error',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ErrorActionButton(
                label: '重试',
                primary: true,
                autofocus: true,
                focusNode: _errorRetryFocus,
                onActivate: () => ref.invalidate(categoriesProvider),
                // 最左按钮：← 显式回 SideNav 首项（mobile 无 SideNav 不传）
                onLeftEscape: PlatformService.needsFocusSystem
                    ? () => _sideNavFirstFocus.requestFocus()
                    : null,
              ),
              const SizedBox(width: AppSpacing.md),
              _ErrorActionButton(
                label: '去设置',
                primary: false,
                onActivate: () => context.push('/source'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 首页错误态按钮：TvFocusable 红环+光晕，与全站 TV 视觉一致
class _ErrorActionButton extends StatelessWidget {
  final String label;
  final bool primary;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onActivate;

  /// 按 ← 时退出到 SideNav（仅最左按钮传，确保焦点稳定回左栏）
  final VoidCallback? onLeftEscape;

  const _ErrorActionButton({
    required this.label,
    required this.primary,
    required this.onActivate,
    this.autofocus = false,
    this.focusNode,
    this.onLeftEscape,
  });

  @override
  Widget build(BuildContext context) {
    final core = TvFocusable(
      debugLabel: 'error-action-$label',
      autofocus: autofocus,
      focusNode: focusNode,
      onActivate: onActivate,
      ensureVisibleOnFocus: false,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: BoxDecoration(
            color: primary ? AppColors.netflixRed : AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused
                  ? AppColors.primaryText
                  : (primary ? AppColors.netflixRed : AppColors.divider),
              width: focused ? 1.5 : 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(120),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: AppTypography.body.copyWith(
              color: AppColors.primaryText,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );

    // skipTraversal Focus 仅截 ← 冒泡，不抢焦点：
    // 内层 TvFocusable 的 Focus 先看 KeyEvent，不消耗 ← → 冒到外层触发逃逸
    if (onLeftEscape == null) return core;
    return Focus(
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          onLeftEscape!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: core,
    );
  }
}

/// 分类行包装器（独立消费 categoryItemsProvider）
class _CategoryRailWrapper extends ConsumerWidget {
  final Category category;
  final bool isFirstRail;
  final void Function(VideoItem item) onItemSelected;

  const _CategoryRailWrapper({
    required this.category,
    required this.onItemSelected,
    this.isFirstRail = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providerKey = (siteKey: category.siteKey, categoryId: category.id);
    final items = ref.watch(categoryItemsProvider(providerKey));
    final sites = ref.read(sitesProvider);

    // 找到该分类所属的 Site
    Site? site;
    try {
      site = sites.firstWhere((s) => s.key == category.siteKey);
    } catch (_) {}

    return CategoryRail(
      category: category,
      items: items.whenData((result) => result.items),
      isFirstRail: isFirstRail,
      onItemSelected: onItemSelected,
      onRetry: () => ref.invalidate(categoryItemsProvider(providerKey)),
      onViewMore: site != null
          ? () => context.push(
              '/category',
              extra: {'category': category, 'site': site},
            )
          : null,
    );
  }
}
