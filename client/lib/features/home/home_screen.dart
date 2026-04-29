import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/site.dart';
import '../../data/models/category.dart';
import '../../data/models/video_item.dart';
import '../../data/models/watch_history.dart';
import '../../widgets/top_nav_bar.dart';
import '../../widgets/skeleton_card.dart';
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
  final _urlController = TextEditingController();
  final _scrollController = ScrollController();
  // 方向键「上」的兜底锚点：VideoCard 上键失败时跳回 Banner 播放；Banner 上键跳到顶栏首项
  final _bannerPlayFocus = FocusNode(debugLabel: 'banner-play');
  final _topNavFirstFocus = FocusNode(debugLabel: 'top-nav-home');
  bool _navOpaque = false;
  bool _restoring = true; // 启动时恢复状态中，避免闪现输入界面

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 从 Hive 恢复持久化状态
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreFromStorage());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _scrollController.dispose();
    _bannerPlayFocus.dispose();
    _topNavFirstFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    final opaque = _scrollController.offset > 100;
    if (opaque != _navOpaque) {
      setState(() => _navOpaque = opaque);
    }
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
              final matched =
                  allSites.where((s) => s.key == pluginKey).toList();
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

  void _loadSource() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final site = Site.fromUrl(url);
    ref.read(sitesProvider.notifier).state = [site];
  }

  void _navigateToDetail(VideoItem video) {
    final sites = ref.read(sitesProvider);
    final site = sites.firstWhere((s) => s.key == video.siteKey);
    context.push('/detail', extra: {
      'site': site,
      'videoId': video.id,
      // 「继续观看」行点击时携带历史线路、集数和进度，用于续播定位
      if (video.historyGroupIndex != null)
        'initialGroupIndex': video.historyGroupIndex,
      if (video.historyEpisodeIndex != null)
        'initialEpisodeIndex': video.historyEpisodeIndex,
      if (video.historyPositionMs != null)
        'initialPositionMs': video.historyPositionMs,
    });
  }

  /// Banner「播放」按钮：fetch 详情拿到第一集 → 直接进播放器
  /// 找不到可播剧集时降级到详情页
  Future<void> _playFromBanner(VideoItem video) async {
    final sites = ref.read(sitesProvider);
    final site = sites.firstWhere((s) => s.key == video.siteKey);

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

      await context.push('/player', extra: {
        'videoId': detail.vodId.toString(),
        'siteKey': site.key,
        'videoTitle': detail.vodName,
        'cover': detail.vodPic,
        'episodeGroups': groups,
        'sourceNames': detail.sourceNames,
        'initialGroupIndex': gi,
        'initialEpisodeIndex': ei,
        'initialPositionMs': positionMs,
        'category': detail.vodClass,
      });
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

    return HomeFocusAnchors(
      bannerPlay: _bannerPlayFocus,
      topNavFirst: _topNavFirstFocus,
      ensureBannerVisible: _ensureBannerVisible,
      child: Scaffold(
      body: SafeArea(
        top: isMobile,
        bottom: false,
        child: Stack(
          children: [
            // 主内容
            _restoring
                ? _buildLoadingState()
                : sites.isEmpty
                    ? _buildSourceInput()
                    : _buildMainContent(
                        categories, bannerItems, watchHistory),
            // 顶部导航栏（桌面/TV 端）
            if (!isMobile)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  type: MaterialType.transparency,
                  child: TopNavBar(
                    selectedIndex: 0,
                    onItemSelected: (index) {
                      if (index == 2) context.push('/search');
                      if (index == 3) context.push('/settings');
                    },
                    isOpaque: _navOpaque,
                    firstItemFocusNode: _topNavFirstFocus,
                    downAnchor: _bannerPlayFocus,
                  ),
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
                BottomNavigationBarItem(
                  icon: Icon(Icons.home),
                  label: '首页',
                ),
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

  /// 未配置源时显示输入界面
  Widget _buildSourceInput() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'StreamBox',
              style: AppTypography.display.copyWith(color: AppColors.netflixRed),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              '输入苹果 CMS API 地址开始使用',
              style: AppTypography.body,
            ),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: 600,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlController,
                      decoration: InputDecoration(
                        hintText: 'https://api.example.com/api.php/provide/vod/',
                        hintStyle: AppTypography.body.copyWith(color: AppColors.hintText),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: AppColors.divider),
                        ),
                        filled: true,
                        fillColor: AppColors.cardBackground,
                        isDense: true,
                      ),
                      style: AppTypography.body.copyWith(color: AppColors.primaryText),
                      onSubmitted: (_) => _loadSource(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  ElevatedButton(
                    onPressed: _loadSource,
                    child: const Text('加载'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: () => context.push('/source'),
              child: Text(
                '管理配置源',
                style: AppTypography.body.copyWith(color: AppColors.netflixRed),
              ),
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
          // cacheExtent 覆盖多条 rail，方向键焦点跨 rail 导航时有足够候选
          cacheExtent: 1500,
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
            const SliverToBoxAdapter(
              child: SizedBox(height: AppSpacing.xl),
            ),

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
                  onItemSelected: _navigateToDetail,
                ),
              ),

            // 动态分类行
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final cat = dynamicCategories[index];
                  return _CategoryRailWrapper(
                    category: cat,
                    onItemSelected: _navigateToDetail,
                  );
                },
                childCount: dynamicCategories.length,
              ),
            ),

            // 底部留白
            const SliverToBoxAdapter(
              child: SizedBox(height: AppSpacing.xxl),
            ),
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
          Text('$error', style: AppTypography.body),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                onPressed: () => ref.invalidate(categoriesProvider),
                child: const Text('重试'),
              ),
              const SizedBox(width: AppSpacing.md),
              ElevatedButton(
                onPressed: () => context.push('/source'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.surface,
                  foregroundColor: AppColors.primaryText,
                ),
                child: const Text('去设置'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 分类行包装器（独立消费 categoryItemsProvider）
class _CategoryRailWrapper extends ConsumerWidget {
  final Category category;
  final void Function(VideoItem item) onItemSelected;

  const _CategoryRailWrapper({
    required this.category,
    required this.onItemSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(categoryItemsProvider(category.id));
    final sites = ref.read(sitesProvider);

    // 找到该分类所属的 Site
    Site? site;
    try {
      site = sites.firstWhere((s) => s.key == category.siteKey);
    } catch (_) {}

    return CategoryRail(
      category: category,
      items: items.whenData((result) => result.items),
      onItemSelected: onItemSelected,
      onRetry: () => ref.invalidate(categoryItemsProvider(category.id)),
      onViewMore: site != null
          ? () => context.push('/category', extra: {
                'category': category,
                'site': site,
              })
          : null,
    );
  }
}
