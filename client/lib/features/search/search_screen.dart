import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/util/site_navigation.dart';
import '../../data/models/video_item.dart';
import '../../widgets/tv_back_button.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focus.dart';
import '../home/providers/categories_provider.dart';
import '../home/widgets/video_card.dart';
import 'providers/search_provider.dart';

/// 搜索页
class SearchScreen extends ConsumerStatefulWidget {
  /// 进页时预填的关键词（来自「片源已下架」SnackBar 的「去搜索」action）。
  /// 非空时进页自动触发搜索。
  final String? initialKeyword;

  const SearchScreen({super.key, this.initialKeyword});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasSearched = false;
  bool _autofocusFirstResult = false;

  @override
  void initState() {
    super.initState();
    final kw = widget.initialKeyword?.trim();
    if (kw != null && kw.isNotEmpty) {
      _controller.text = kw;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(kw);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _search([String? keyword]) {
    final kw = keyword ?? _controller.text.trim();
    if (kw.isEmpty) return;
    if (keyword != null) _controller.text = kw;
    setState(() {
      _hasSearched = true;
      _autofocusFirstResult = true;
    });
    ref.read(searchProvider.notifier).search(kw);
    _focusNode.unfocus();
  }

  void _clearSearch() {
    _controller.clear();
    setState(() {
      _hasSearched = false;
      _autofocusFirstResult = false;
    });
    ref.read(searchProvider.notifier).clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _handleBack() {
    if (_hasSearched) {
      _clearSearch();
      return;
    }
    if (context.canPop()) context.pop();
  }

  /// TV 大屏不暴露原始 stack trace。常见错误用人类语言；其它截短到 60 字符。
  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('500')) return '服务暂不可用';
    if (s.contains('SocketException') || s.contains('TimeoutException')) {
      return '网络不可达';
    }
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  void _navigateToDetail(VideoItem video) {
    navigateToVideoDetail(
      context,
      ref,
      siteKey: video.siteKey,
      videoId: video.id,
      title: video.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchProvider);
    final isCompact = MediaQuery.sizeOf(context).width < 600;
    final hPad = isCompact ? AppSpacing.md : AppSpacing.xl;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _handleBack,
        const SingleActivator(LogicalKeyboardKey.browserBack): _handleBack,
        const SingleActivator(LogicalKeyboardKey.gameButtonB): _handleBack,
      },
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 56,
          leading: const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TvBackButton(),
            ),
          ),
          title: const Text('搜索'),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 搜索栏 ──
            Padding(
              padding: EdgeInsets.fromLTRB(
                hPad,
                AppSpacing.md,
                hPad,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      autofocus: !_hasSearched,
                      decoration: InputDecoration(
                        hintText: '输入影片名称...',
                        hintStyle: AppTypography.body.copyWith(
                          color: AppColors.hintText,
                        ),
                        prefixIcon: const Icon(
                          Icons.search,
                          color: AppColors.hintText,
                        ),
                        suffixIcon: _hasSearched
                            ? IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: AppColors.hintText,
                                  size: 18,
                                ),
                                onPressed: _clearSearch,
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppColors.divider,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppColors.divider,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: AppColors.netflixRed,
                            width: 2,
                          ),
                        ),
                        filled: true,
                        fillColor: AppColors.cardBackground,
                        isDense: true,
                      ),
                      style: AppTypography.body.copyWith(
                        color: AppColors.primaryText,
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  TvActionButton.primary(
                    icon: Icons.search,
                    label: '搜索',
                    compact: true,
                    debugLabel: 'search-submit',
                    onActivate: _search,
                  ),
                ],
              ),
            ),

            // ── 内容区 ──
            Expanded(
              child: _hasSearched
                  ? _buildResults(results, hPad)
                  : _SearchHome(
                      onKeywordTap: _search,
                      onVideoTap: _navigateToDetail,
                      onTopRowUp: () => _focusNode.requestFocus(),
                      hPad: hPad,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(AsyncValue<List<VideoItem>> results, double hPad) {
    final progress = ref.watch(searchProgressProvider);
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              progress.completed < progress.total
                  ? '正在搜索 ${progress.completed}/${progress.total} 个片源'
                  : '已搜索 ${progress.total} 个片源',
              style: AppTypography.caption,
            ),
          ),
        ),
        Expanded(
          child: results.when(
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppColors.netflixRed),
            ),
            error: (e, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '搜索失败: ${_friendlyError(e)}',
                    style: AppTypography.body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TvActionButton.secondary(
                    icon: Icons.refresh,
                    label: '重试',
                    autofocus: true,
                    debugLabel: 'search-error-retry',
                    onActivate: _search,
                  ),
                ],
              ),
            ),
            data: (items) {
              if (items.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        progress.total == 0
                            ? '暂无可用的搜索片源，请前往设置启用或重新检测'
                            : '未找到「${_controller.text}」相关内容',
                        style: AppTypography.body,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TvActionButton.secondary(
                        icon: Icons.refresh,
                        label: '清空重搜',
                        autofocus: true,
                        debugLabel: 'search-empty-clear',
                        onActivate: _clearSearch,
                      ),
                    ],
                  ),
                );
              }
              final autofocusFirst = _autofocusFirstResult;
              if (autofocusFirst) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _autofocusFirstResult = false);
                });
              }
              return _ResultGrid(
                items: items,
                hPad: hPad,
                autofocusFirst: autofocusFirst,
                onTopRowUp: () => _focusNode.requestFocus(),
                onItemSelected: _navigateToDetail,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 搜索首页：搜索历史 + 最近更新
class _SearchHome extends ConsumerWidget {
  final void Function(String keyword) onKeywordTap;
  final void Function(VideoItem video) onVideoTap;
  final VoidCallback onTopRowUp;
  final double hPad;

  const _SearchHome({
    required this.onKeywordTap,
    required this.onVideoTap,
    required this.onTopRowUp,
    required this.hPad,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryProvider);
    final latestAsync = ref.watch(latestUpdatesProvider);

    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(hPad, AppSpacing.sm, hPad, AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 搜索历史 ──
            if (history.isNotEmpty) ...[
              Row(
                children: [
                  Text('搜索历史', style: AppTypography.headline2),
                  const Spacer(),
                  TvActionButton.text(
                    icon: Icons.delete_outline,
                    label: '清空',
                    debugLabel: 'history-clear',
                    onActivate: () {
                      ref.read(searchHistoryStorageProvider).clearAll();
                      ref.invalidate(searchHistoryProvider);
                    },
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: history
                    .map(
                      (kw) => _HistoryChip(
                        label: kw,
                        onTap: () => onKeywordTap(kw),
                        onDelete: () {
                          ref.read(searchHistoryStorageProvider).remove(kw);
                          ref.invalidate(searchHistoryProvider);
                        },
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // ── 最近更新 ──
            Text('最近更新', style: AppTypography.headline2),
            const SizedBox(height: AppSpacing.md),
            latestAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.only(top: AppSpacing.xxl),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.netflixRed),
                ),
              ),
              error: (_, _) => _EmptyAction(
                message: '加载失败',
                actionLabel: '重试',
                onAction: () => ref.invalidate(latestUpdatesProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return _EmptyAction(
                    message: '暂无数据',
                    actionLabel: '刷新',
                    onAction: () => ref.invalidate(latestUpdatesProvider),
                  );
                }
                return _LatestGrid(
                  items: items,
                  hPad: hPad,
                  onTopRowUp: onTopRowUp,
                  onItemSelected: onVideoTap,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态 / 错误态可聚焦兜底
class _EmptyAction extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _EmptyAction({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Row(
        children: [
          Text(
            message,
            style: AppTypography.body.copyWith(color: AppColors.hintText),
          ),
          const SizedBox(width: AppSpacing.md),
          TvActionButton.secondary(
            icon: Icons.refresh,
            label: actionLabel,
            compact: true,
            debugLabel: 'empty-action-$actionLabel',
            onActivate: onAction,
          ),
        ],
      ),
    );
  }
}

/// 搜索历史标签
///
/// TV 交互（统一走 [TvFocusable]）：
/// - OK     = 搜索（[onTap]）
/// - 长按 OK = 删除（[onDelete]）
///
/// 内嵌的 × icon 仅作视觉提示，不参与焦点流。
class _HistoryChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HistoryChip({
    required this.label,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'history-chip-$label',
      onActivate: onTap,
      onLongActivate: onDelete,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: focused
                ? AppColors.netflixRed.withAlpha(40)
                : AppColors.cardBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: focused ? AppColors.netflixRed : Colors.transparent,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppTypography.body.copyWith(
                  color: AppColors.primaryText,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.close,
                size: 14,
                color: focused ? AppColors.primaryText : AppColors.hintText,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 最近更新网格（不可滚动，嵌入 SingleChildScrollView）
class _LatestGrid extends StatelessWidget {
  final List<VideoItem> items;
  final double hPad;
  final VoidCallback? onTopRowUp;
  final void Function(VideoItem) onItemSelected;

  const _LatestGrid({
    required this.items,
    required this.hPad,
    required this.onItemSelected,
    this.onTopRowUp,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width - hPad * 2;
    final crossAxisCount = AppSpacing.gridColumns(
      MediaQuery.of(context).size.width,
    );
    final spacing = AppSpacing.md;
    final cardWidth = (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
    final cardHeight =
        cardWidth * (AppSpacing.cardHeight / AppSpacing.cardWidth);

    return Wrap(
      spacing: spacing,
      runSpacing: spacing + 16,
      children: List.generate(items.length, (idx) {
        final video = items[idx];
        return SizedBox(
          width: cardWidth,
          height: cardHeight,
          child: VideoCard(
            video: video,
            onUpEdge: idx < crossAxisCount ? onTopRowUp : null,
            onSelected: () => onItemSelected(video),
            onFocused: () {},
          ),
        );
      }),
    );
  }
}

/// 搜索结果网格
class _ResultGrid extends ConsumerWidget {
  final List<VideoItem> items;
  final double hPad;
  final bool autofocusFirst;
  final VoidCallback? onTopRowUp;
  final void Function(VideoItem) onItemSelected;

  const _ResultGrid({
    required this.items,
    required this.hPad,
    required this.onItemSelected,
    this.autofocusFirst = false,
    this.onTopRowUp,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = AppSpacing.gridColumns(width);

    return GridView.builder(
      padding: EdgeInsets.fromLTRB(hPad, AppSpacing.lg, hPad, AppSpacing.xxl),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: AppSpacing.cardWidth / AppSpacing.cardHeight,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md + 16, // 留焦点 scale 空间
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final video = items[index];
        return VideoCard(
          video: video,
          sourceName: ref
              .watch(sitesProvider)
              .where((s) => s.key == video.siteKey)
              .firstOrNull
              ?.name,
          autofocus: autofocusFirst && index == 0,
          onUpEdge: index < crossAxisCount ? onTopRowUp : null,
          onSelected: () => onItemSelected(video),
          onFocused: () {},
        );
      },
    );
  }
}
