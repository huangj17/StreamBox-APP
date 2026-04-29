import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/platform/platform_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/category.dart';
import '../../data/models/site.dart';
import '../../data/models/video_item.dart';
import 'providers/categories_provider.dart';
import 'widgets/video_card.dart';

/// 分类详情页 — 展示某个分类下的全部视频，支持年份筛选和本地排序
class CategoryDetailScreen extends ConsumerStatefulWidget {
  final Category category;
  final Site site;

  const CategoryDetailScreen({
    super.key,
    required this.category,
    required this.site,
  });

  @override
  ConsumerState<CategoryDetailScreen> createState() =>
      _CategoryDetailScreenState();
}

class _CategoryDetailScreenState extends ConsumerState<CategoryDetailScreen> {
  final _scrollController = ScrollController();
  final _items = <VideoItem>[];
  int _page = 1;
  int _pageCount = 1;
  bool _loading = false;

  String? _selectedYear;
  bool _sortByScore = false;
  List<VideoItem>? _sortedCache; // 缓存排序结果，避免每次 build 重排

  @override
  void initState() {
    super.initState();
    _loadPage();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      _loadPage();
    }
  }

  Future<void> _loadPage() async {
    if (_loading || _page > _pageCount) return;
    setState(() => _loading = true);

    try {
      final api = ref.read(cmsApiProvider);
      final result = await api.fetchVideoList(
        site: widget.site,
        categoryId: widget.category.id,
        page: _page,
        year: _selectedYear,
      );
      setState(() {
        _items.addAll(result.items);
        _pageCount = result.pageCount;
        _page++;
        _invalidateSortCache();
      });
    } catch (_) {}

    setState(() => _loading = false);
  }

  void _resetAndReload() {
    _items.clear();
    _invalidateSortCache();
    _page = 1;
    _pageCount = 1;
    _loadPage();
  }

  List<VideoItem> get _sortedItems {
    if (!_sortByScore) return _items;
    return _sortedCache ??= List<VideoItem>.from(_items)
      ..sort((a, b) {
        final sa = double.tryParse(a.score ?? '') ?? 0;
        final sb = double.tryParse(b.score ?? '') ?? 0;
        return sb.compareTo(sa);
      });
  }

  void _invalidateSortCache() {
    _sortedCache = null;
  }

  void _navigateToDetail(VideoItem video) {
    context.push('/detail', extra: {
      'site': widget.site,
      'videoId': video.id,
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = AppSpacing.gridColumns(width);
    final sorted = _sortedItems;
    final currentYear = DateTime.now().year;

    return Scaffold(
      appBar: AppBar(title: Text(widget.category.name)),
      body: Column(
        children: [
          // ── 筛选栏 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.sm,
            ),
            child: Row(
              children: [
                // 年份下拉：PopupMenuButton 自带 focus，外层包一个 Focus
                // 装饰器给 TV 显示红色焦点环
                _FocusRing(
                  child: PopupMenuButton<String>(
                    onSelected: (year) {
                      final actual = year.isEmpty ? null : year;
                      if (actual != _selectedYear) {
                        setState(() {
                          _selectedYear = actual;
                          _sortByScore = false;
                        });
                        _resetAndReload();
                      }
                    },
                    color: AppColors.cardBackground,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    itemBuilder: (_) => [
                      _buildYearItem(''),
                      for (var y = currentYear; y >= 2020; y--)
                        _buildYearItem(y.toString()),
                    ],
                    child: _ChipLabel(
                      label: _selectedYear ?? '全部年份',
                      active: _selectedYear != null,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // 排序切换：原 GestureDetector 遥控器进不去，改为可聚焦
                _FocusableChip(
                  label: _sortByScore ? '评分最高' : '最新更新',
                  active: _sortByScore,
                  onTap: () => setState(() {
                    _sortByScore = !_sortByScore;
                    _invalidateSortCache();
                  }),
                ),
              ],
            ),
          ),

          // ── 内容区 ──
          Expanded(
            child: _items.isEmpty && _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppColors.netflixRed),
                  )
                : _items.isEmpty && !_loading
                    ? Center(
                        child: Text('暂无内容',
                            style: AppTypography.body
                                .copyWith(color: AppColors.hintText)),
                      )
                    : GridView.builder(
                        controller: _scrollController,
                        cacheExtent: 400, // 提前渲染 400dp，减少快速滚动白屏
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xl, AppSpacing.sm,
                          AppSpacing.xl, AppSpacing.xxl,
                        ),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio:
                              AppSpacing.cardWidth / AppSpacing.cardHeight,
                          crossAxisSpacing: AppSpacing.md,
                          mainAxisSpacing: AppSpacing.md + 40,
                        ),
                        itemCount:
                            sorted.length + (_page <= _pageCount ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index >= sorted.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(AppSpacing.md),
                                child: CircularProgressIndicator(
                                    color: AppColors.netflixRed,
                                    strokeWidth: 2),
                              ),
                            );
                          }
                          final video = sorted[index];
                          return VideoCard(
                            video: video,
                            onSelected: () => _navigateToDetail(video),
                            onFocused: () {},
                            // TV/桌面键盘进页面把默认焦点落在第一张卡，
                            // 不然用户按方向键不知道焦点在哪
                            autofocus: index == 0 &&
                                PlatformService.needsFocusSystem,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  PopupMenuEntry<String> _buildYearItem(String year) {
    final isAll = year.isEmpty;
    final isSelected = isAll ? _selectedYear == null : year == _selectedYear;
    return PopupMenuItem<String>(
      value: year,
      child: Text(
        isAll ? '全部' : year,
        style: AppTypography.body.copyWith(
          color: isSelected ? AppColors.netflixRed : AppColors.primaryText,
          fontSize: 14,
        ),
      ),
    );
  }
}

/// 筛选标签样式
class _ChipLabel extends StatelessWidget {
  final String label;
  final bool active;

  const _ChipLabel({required this.label, this.active = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active ? AppColors.netflixRed.withAlpha(30) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: active
            ? Border.all(color: AppColors.netflixRed.withAlpha(100))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTypography.caption.copyWith(
              color: active ? AppColors.netflixRed : AppColors.primaryText,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.unfold_more,
            size: 14,
            color: active ? AppColors.netflixRed : AppColors.hintText,
          ),
        ],
      ),
    );
  }
}

/// 装饰型焦点环：不抢占焦点（`canRequestFocus: false`），只在子孙拿到
/// 焦点时画一圈红色描边——给 PopupMenuButton / Switch 这类自带 focus
/// 逻辑的原生控件补一个 TV 可见的视觉指示
class _FocusRing extends StatefulWidget {
  final Widget child;

  const _FocusRing({required this.child});

  @override
  State<_FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<_FocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: _focused ? AppColors.netflixRed : Colors.transparent,
            width: 2,
          ),
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
        child: widget.child,
      ),
    );
  }
}

/// 可聚焦的筛选 chip：Enter/OK 触发 onTap，焦点态红色外框 + 阴影
class _FocusableChip extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FocusableChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  State<_FocusableChip> createState() => _FocusableChipState();
}

class _FocusableChipState extends State<_FocusableChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _focused ? AppColors.netflixRed : Colors.transparent,
              width: 2,
            ),
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
          child: _ChipLabel(label: widget.label, active: widget.active),
        ),
      ),
    );
  }
}
