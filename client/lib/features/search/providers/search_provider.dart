import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/video_item.dart';
import '../../../data/models/site.dart';
import '../../../data/models/video_list_result.dart';
import '../../home/providers/categories_provider.dart';

/// 搜索结果状态（AsyncNotifier，支持跨源聚合）
class SearchNotifier extends AsyncNotifier<List<VideoItem>> {
  static const _perSiteBudget = Duration(seconds: 4);
  int _generation = 0;
  List<CancelToken> _activeTokens = [];
  bool _disposed = false;

  @override
  Future<List<VideoItem>> build() async {
    ref.onDispose(() {
      _disposed = true;
      _cancelActiveSearch();
    });
    ref.listen<List<Site>>(sitesProvider, (previous, next) {
      String signature(List<Site> sites) =>
          sites.map((s) => '${s.key}:${s.api}:${s.searchable}').join('|');
      if (previous != null && signature(previous) != signature(next)) clear();
    });
    return [];
  }

  Future<void> search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      clear();
      return;
    }

    final generation = ++_generation;
    _cancelActiveSearch();

    // 保存搜索历史
    unawaited(ref.read(searchHistoryStorageProvider).add(trimmed));
    ref.invalidate(searchHistoryProvider);

    state = const AsyncValue.loading();
    try {
      final sites = ref.read(searchSitesProvider);
      final api = ref.read(cmsApiProvider);
      final eligibleSites = sites
          .where((site) => site.isEnabled && site.searchable)
          .toList();
      final tokens = List.generate(eligibleSites.length, (_) => CancelToken());
      _activeTokens = tokens;
      ref.read(searchProgressProvider.notifier).state = (
        completed: 0,
        total: eligibleSites.length,
      );
      final items = <VideoItem>[];
      var nextIndex = 0;
      var completed = 0;
      Future<void> worker() async {
        while (nextIndex < eligibleSites.length &&
            !_disposed &&
            generation == _generation) {
          final index = nextIndex++;
          final site = eligibleSites[index];
          final token = tokens[index];
          try {
            final result = await api
                .search(site: site, keyword: trimmed, cancelToken: token)
                .timeout(
                  _perSiteBudget,
                  onTimeout: () {
                    token.cancel('搜索数据源超时');
                    return const VideoListResult(
                      items: [],
                      total: 0,
                      pageCount: 1,
                    );
                  },
                );
            if (_disposed || generation != _generation) return;
            items.addAll(result.items);
          } catch (_) {
            if (_disposed || generation != _generation) return;
          }
          completed++;
          ref.read(searchProgressProvider.notifier).state = (
            completed: completed,
            total: eligibleSites.length,
          );
          if (items.isNotEmpty) {
            state = AsyncValue.data(List.unmodifiable(items));
          }
        }
      }

      await Future.wait(
        List.generate(eligibleSites.length.clamp(0, 4), (_) => worker()),
      );
      if (_disposed || generation != _generation) return;
      state = AsyncValue.data(List.unmodifiable(items));
    } catch (error, stackTrace) {
      if (generation != _generation) return;
      if (!_disposed && generation == _generation) {
        state = AsyncValue.error(error, stackTrace);
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _activeTokens = [];
        final progress = ref.read(searchProgressProvider);
        ref.read(searchProgressProvider.notifier).state = (
          completed: progress.total,
          total: progress.total,
        );
      }
    }
  }

  void clear() {
    _generation++;
    _cancelActiveSearch();
    ref.read(searchProgressProvider.notifier).state = (completed: 0, total: 0);
    state = const AsyncValue.data([]);
  }

  void _cancelActiveSearch() {
    for (final token in _activeTokens) {
      if (!token.isCancelled) token.cancel('搜索请求已被替换');
    }
    _activeTokens = [];
  }
}

final searchProgressProvider = StateProvider<({int completed, int total})>(
  (ref) => (completed: 0, total: 0),
);

final searchProvider = AsyncNotifierProvider<SearchNotifier, List<VideoItem>>(
  SearchNotifier.new,
);

/// 搜索历史关键词列表
final searchHistoryProvider = Provider<List<String>>((ref) {
  final storage = ref.watch(searchHistoryStorageProvider);
  return storage.getAll();
});

/// 最近更新（取第一个 site 的第一页数据，不指定分类）
final latestUpdatesProvider = FutureProvider.autoDispose<List<VideoItem>>((
  ref,
) async {
  final sites = ref.watch(homeSitesProvider);
  if (sites.isEmpty) return [];

  final api = ref.read(cmsApiProvider);
  try {
    final result = await api.fetchVideoList(
      site: sites.first,
      categoryId: '',
      page: 1,
    );
    return result.items.take(12).toList();
  } catch (_) {
    return [];
  }
});
