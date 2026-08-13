import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/home/providers/categories_provider.dart';

/// 跳转到视频详情页，统一处理「源已下架/未启用」情况。
///
/// 旧实现 6 处用 `sites.firstWhere(...) catch (_) {}` 静默吞 `StateError`，
/// 用户感受是「点不动」。本 helper 找不到源时弹 SnackBar 反馈，并提供
/// 「去搜索」action 跨源回查同名内容。
///
/// 用于：history / favorites / search 最近更新 / home 卡片 / banner 播放等。
Future<void> navigateToVideoDetail(
  BuildContext context,
  WidgetRef ref, {
  required String siteKey,
  required String videoId,
  required String title,
  int? initialGroupIndex,
  int? initialEpisodeIndex,
  int? initialPositionMs,
}) async {
  final sites = ref.read(sitesProvider);
  final matched = sites.where((s) => s.key == siteKey).toList();
  if (matched.isEmpty) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('「$title」所在的片源已下架或未启用'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '去搜索',
          onPressed: () => context.push('/search', extra: {'keyword': title}),
        ),
      ),
    );
    return;
  }

  if (!context.mounted) return;
  context.push(
    '/detail',
    extra: {
      'site': matched.first,
      'videoId': videoId,
      'initialGroupIndex': ?initialGroupIndex,
      'initialEpisodeIndex': ?initialEpisodeIndex,
      'initialPositionMs': ?initialPositionMs,
    },
  );
}

/// 当前是否还有该 [siteKey] 的活跃源。用于历史/收藏 tile 视觉降级判断。
bool isSiteActive(WidgetRef ref, String siteKey) {
  final sites = ref.read(sitesProvider);
  return sites.any((s) => s.key == siteKey);
}
