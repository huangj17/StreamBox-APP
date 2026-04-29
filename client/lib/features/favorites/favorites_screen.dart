import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/video_item.dart';
import '../home/providers/categories_provider.dart';
import '../home/widgets/video_card.dart';

/// 收藏列表页
class FavoritesScreen extends ConsumerWidget {
  final bool embedded;
  const FavoritesScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(favoritesProvider);
    final items = favorites.map(VideoItem.fromFavorite).toList();

    final body = items.isEmpty
          ? Center(
              child: Text(
                '暂无收藏内容',
                style: AppTypography.body
                    .copyWith(color: AppColors.secondaryText),
              ),
            )
          : _FavoritesGrid(
              items: items,
              onItemSelected: (video) => _navigateToDetail(context, ref, video),
            );

    if (embedded) {
      return Column(
        children: [
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _confirmClearAll(context, ref),
                    child: Text('清空',
                        style: AppTypography.body
                            .copyWith(color: AppColors.error)),
                  ),
                ],
              ),
            ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () => _confirmClearAll(context, ref),
              child: Text('清空',
                  style: AppTypography.body.copyWith(color: AppColors.error)),
            ),
        ],
      ),
      body: body,
    );
  }

  void _navigateToDetail(
      BuildContext context, WidgetRef ref, VideoItem video) {
    final sites = ref.read(sitesProvider);
    try {
      final site = sites.firstWhere((s) => s.key == video.siteKey);
      context.push('/detail', extra: {
        'site': site,
        'videoId': video.id,
      });
    } catch (_) {}
  }

  void _confirmClearAll(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('清空收藏'),
        content: const Text('确定要清空全部收藏吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              ref.read(favoriteStorageProvider).clearAll();
              ref.invalidate(favoritesProvider);
              Navigator.pop(ctx);
            },
            child: Text('清空',
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }
}

class _FavoritesGrid extends StatelessWidget {
  final List<VideoItem> items;
  final void Function(VideoItem) onItemSelected;

  const _FavoritesGrid({required this.items, required this.onItemSelected});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = AppSpacing.gridColumns(width);

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.xxl,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: AppSpacing.cardWidth / AppSpacing.cardHeight,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md + 40,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final video = items[index];
        return VideoCard(
          video: video,
          autofocus: index == 0,
          onSelected: () => onItemSelected(video),
          onFocused: () {},
        );
      },
    );
  }
}
