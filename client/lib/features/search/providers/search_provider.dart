import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/video_item.dart';
import '../../../data/models/video_list_result.dart';
import '../../home/providers/categories_provider.dart';

/// 搜索结果状态（AsyncNotifier，支持跨源聚合）
class SearchNotifier extends AsyncNotifier<List<VideoItem>> {
  static const _perSiteBudget = Duration(seconds: 4);
  int _generation = 0;
  List<CancelToken> _activeTokens = [];

  @override
  Future<List<VideoItem>> build() async {
    ref.onDispose(_cancelActiveSearch);
    return [];
  }

  Future<void> search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      _generation++;
      _cancelActiveSearch();
      state = const AsyncValue.data([]);
      return;
    }

    final generation = ++_generation;
    _cancelActiveSearch();

    // 保存搜索历史
    unawaited(ref.read(searchHistoryStorageProvider).add(trimmed));
    ref.invalidate(searchHistoryProvider);

    state = const AsyncValue.loading();
    try {
      final sites = ref.read(sitesProvider);
      final api = ref.read(cmsApiProvider);
      final eligibleSites = sites
          .where((site) => site.isEnabled && site.searchable)
          .toList();
      final tokens = List.generate(eligibleSites.length, (_) => CancelToken());
      _activeTokens = tokens;

      final futures = eligibleSites.indexed.map((entry) async {
        final (index, site) = entry;
        final token = tokens[index];
        try {
          return await api
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
        } catch (_) {
          return const VideoListResult(items: [], total: 0, pageCount: 1);
        }
      });

      final results = await Future.wait(futures);
      if (generation != _generation) return;
      state = AsyncValue.data(results.expand((r) => r.items).toList());
    } catch (error, stackTrace) {
      if (generation != _generation) return;
      state = AsyncValue.error(error, stackTrace);
    } finally {
      if (generation == _generation) _activeTokens = [];
    }
  }

  void clear() {
    _generation++;
    _cancelActiveSearch();
    state = const AsyncValue.data([]);
  }

  void _cancelActiveSearch() {
    for (final token in _activeTokens) {
      if (!token.isCancelled) token.cancel('搜索请求已被替换');
    }
    _activeTokens = [];
  }
}

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
  final sites = ref.watch(sitesProvider);
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
