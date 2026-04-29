import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/watch_history.dart';
import '../../data/models/video_item.dart';
import '../../widgets/resolvable_cover.dart';
import '../home/providers/categories_provider.dart';

/// 完整播放历史页（不限条数，包含已看完）
class HistoryScreen extends ConsumerStatefulWidget {
  final bool embedded;
  const HistoryScreen({super.key, this.embedded = false});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  List<WatchHistory> _histories = [];

  @override
  void initState() {
    super.initState();
    _loadHistories();
  }

  void _loadHistories() {
    final storage = ref.read(historyStorageProvider);
    setState(() => _histories = storage.getAllUnfiltered());
  }

  void _navigateToDetail(VideoItem video) {
    final sites = ref.read(sitesProvider);
    try {
      final site = sites.firstWhere((s) => s.key == video.siteKey);
      context.push('/detail', extra: {
        'site': site,
        'videoId': video.id,
        if (video.historyGroupIndex != null)
          'initialGroupIndex': video.historyGroupIndex,
        if (video.historyEpisodeIndex != null)
          'initialEpisodeIndex': video.historyEpisodeIndex,
        if (video.historyPositionMs != null)
          'initialPositionMs': video.historyPositionMs,
      });
    } catch (_) {}
  }

  void _deleteItem(WatchHistory h) async {
    final storage = ref.read(historyStorageProvider);
    await storage.delete(h.storageKey);
    ref.invalidate(watchHistoryProvider);
    _loadHistories();
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('清空历史'),
        content: const Text('确定要清空全部播放历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final storage = ref.read(historyStorageProvider);
              await storage.clearAll();
              ref.invalidate(watchHistoryProvider);
              _loadHistories();
              if (context.mounted) Navigator.pop(ctx);
            },
            child: Text('清空',
                style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _histories.isEmpty
        ? Center(
            child: Text(
              '暂无播放历史',
              style: AppTypography.body
                  .copyWith(color: AppColors.secondaryText),
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.lg,
            ),
            itemCount: _histories.length,
            itemBuilder: (context, index) {
              final h = _histories[index];
              return _HistoryTile(
                history: h,
                onTap: () => _navigateToDetail(VideoItem.fromHistory(h)),
                onDelete: () => _deleteItem(h),
              );
            },
          );

    if (widget.embedded) {
      return Column(
        children: [
          if (_histories.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _confirmClearAll,
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
        title: const Text('播放历史'),
        actions: [
          if (_histories.isNotEmpty)
            TextButton(
              onPressed: _confirmClearAll,
              child: Text(
                '清空',
                style: AppTypography.body.copyWith(color: AppColors.error),
              ),
            ),
        ],
      ),
      body: body,
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final WatchHistory history;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HistoryTile({
    required this.history,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isFinished = history.progress >= 0.95;
    final progressText = isFinished
        ? '已看完'
        : '${_formatDuration(history.positionMs)} / ${_formatDuration(history.durationMs)}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            // 封面缩略图 + 进度条
            SizedBox(
              width: 160,
              height: 90,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 160,
                      height: 90,
                      child: ResolvableCover(
                        directUrl: history.cover,
                        title: history.title,
                        seed: '${history.siteKey}:${history.videoId}',
                        fit: BoxFit.cover,
                        memCacheWidth: 320,
                        letterScale: 0.5,
                      ),
                    ),
                  ),
                  // 底部进度条
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(6),
                        bottomRight: Radius.circular(6),
                      ),
                      child: LinearProgressIndicator(
                        value: history.progress.clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: AppColors.hintText.withAlpha(77),
                        valueColor: AlwaysStoppedAnimation(
                          isFinished
                              ? AppColors.success
                              : AppColors.netflixRed,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            // 信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    history.title,
                    style: AppTypography.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    history.episodeName,
                    style: AppTypography.caption
                        .copyWith(color: AppColors.secondaryText),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    progressText,
                    style: AppTypography.caption
                        .copyWith(color: AppColors.hintText),
                  ),
                ],
              ),
            ),
            // 删除按钮
            IconButton(
              icon: const Icon(Icons.close, color: AppColors.hintText, size: 20),
              onPressed: onDelete,
              tooltip: '删除',
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
