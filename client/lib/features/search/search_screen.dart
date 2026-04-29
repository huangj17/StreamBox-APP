import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/video_item.dart';
import '../home/providers/categories_provider.dart';
import '../home/widgets/video_card.dart';
import 'providers/search_provider.dart';

/// 搜索页
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasSearched = false;

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
    setState(() => _hasSearched = true);
    ref.read(searchProvider.notifier).search(kw);
    _focusNode.unfocus();
  }

  void _clearSearch() {
    _controller.clear();
    setState(() => _hasSearched = false);
    ref.read(searchProvider.notifier).clear();
  }

  void _navigateToDetail(VideoItem video) {
    final sites = ref.read(sitesProvider);
    try {
      final site = sites.firstWhere((s) => s.key == video.siteKey);
      context.push('/detail', extra: {
        'site': site,
        'videoId': video.id,
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchProvider);
    final isCompact = MediaQuery.sizeOf(context).width < 600;
    final hPad = isCompact ? AppSpacing.md : AppSpacing.xl;

    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 搜索栏 ──
          Padding(
            padding: EdgeInsets.fromLTRB(
              hPad, AppSpacing.md, hPad, AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: '输入影片名称...',
                      hintStyle:
                          AppTypography.body.copyWith(color: AppColors.hintText),
                      prefixIcon: const Icon(Icons.search,
                          color: AppColors.hintText),
                      suffixIcon: _hasSearched
                          ? IconButton(
                              icon: const Icon(Icons.close,
                                  color: AppColors.hintText, size: 18),
                              onPressed: _clearSearch,
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppColors.divider),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppColors.divider),
                      ),
                      filled: true,
                      fillColor: AppColors.cardBackground,
                      isDense: true,
                    ),
                    style: AppTypography.body
                        .copyWith(color: AppColors.primaryText),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                ElevatedButton(
                  onPressed: _search,
                  child: const Text('搜索'),
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
                    hPad: hPad,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(AsyncValue<List<VideoItem>> results, double hPad) {
    return results.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: AppColors.netflixRed),
      ),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('搜索失败: $e', style: AppTypography.body),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _search,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              '未找到「${_controller.text}」相关内容',
              style: AppTypography.body,
            ),
          );
        }
        return _ResultGrid(
          items: items,
          hPad: hPad,
          onItemSelected: _navigateToDetail,
        );
      },
    );
  }
}

/// 搜索首页：搜索历史 + 最近更新
class _SearchHome extends ConsumerWidget {
  final void Function(String keyword) onKeywordTap;
  final void Function(VideoItem video) onVideoTap;
  final double hPad;

  const _SearchHome({
    required this.onKeywordTap,
    required this.onVideoTap,
    required this.hPad,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryProvider);
    final latestAsync = ref.watch(latestUpdatesProvider);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        hPad, AppSpacing.sm, hPad, AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 搜索历史 ──
          if (history.isNotEmpty) ...[
            Row(
              children: [
                Text('搜索历史', style: AppTypography.headline2),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    ref.read(searchHistoryStorageProvider).clearAll();
                    ref.invalidate(searchHistoryProvider);
                  },
                  child: Text(
                    '清空',
                    style: AppTypography.caption
                        .copyWith(color: AppColors.hintText),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: history.map((kw) => _HistoryChip(
                label: kw,
                onTap: () => onKeywordTap(kw),
                onDelete: () {
                  ref.read(searchHistoryStorageProvider).remove(kw);
                  ref.invalidate(searchHistoryProvider);
                },
              )).toList(),
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
            error: (_, _) => Text(
              '加载失败',
              style: AppTypography.body.copyWith(color: AppColors.hintText),
            ),
            data: (items) {
              if (items.isEmpty) {
                return Text(
                  '暂无数据',
                  style: AppTypography.body.copyWith(color: AppColors.hintText),
                );
              }
              return _LatestGrid(
                items: items,
                hPad: hPad,
                onItemSelected: onVideoTap,
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 搜索历史标签
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
    return Material(
      color: AppColors.cardBackground,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 4, top: 6, bottom: 6),
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
              const SizedBox(width: 2),
              GestureDetector(
                onTap: onDelete,
                child: const Icon(Icons.close,
                    size: 14, color: AppColors.hintText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最近更新网格（不可滚动，嵌入 SingleChildScrollView）
class _LatestGrid extends StatelessWidget {
  final List<VideoItem> items;
  final double hPad;
  final void Function(VideoItem) onItemSelected;

  const _LatestGrid({
    required this.items,
    required this.hPad,
    required this.onItemSelected,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width - hPad * 2;
    final crossAxisCount = AppSpacing.gridColumns(
      MediaQuery.of(context).size.width,
    );
    final spacing = AppSpacing.md;
    final cardWidth = (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
    final cardHeight = cardWidth * (AppSpacing.cardHeight / AppSpacing.cardWidth);

    return Wrap(
      spacing: spacing,
      runSpacing: spacing + 16,
      children: items.map((video) => SizedBox(
        width: cardWidth,
        height: cardHeight,
        child: VideoCard(
          video: video,
          onSelected: () => onItemSelected(video),
          onFocused: () {},
        ),
      )).toList(),
    );
  }
}

/// 搜索结果网格
class _ResultGrid extends StatelessWidget {
  final List<VideoItem> items;
  final double hPad;
  final void Function(VideoItem) onItemSelected;

  const _ResultGrid({
    required this.items,
    required this.hPad,
    required this.onItemSelected,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = AppSpacing.gridColumns(width);

    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        hPad, AppSpacing.lg, hPad, AppSpacing.xxl,
      ),
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
          onSelected: () => onItemSelected(video),
          onFocused: () {},
        );
      },
    );
  }
}
