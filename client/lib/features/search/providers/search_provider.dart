import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/video_item.dart';
import '../../../data/models/video_list_result.dart';
import '../../home/providers/categories_provider.dart';

/// 搜索结果状态（AsyncNotifier，支持跨源聚合）
class SearchNotifier extends AsyncNotifier<List<VideoItem>> {
  @override
  Future<List<VideoItem>> build() async => [];

  Future<void> search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      state = const AsyncValue.data([]);
      return;
    }

    // 保存搜索历史
    ref.read(searchHistoryStorageProvider).add(trimmed);
    ref.invalidate(searchHistoryProvider);

    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final sites = ref.read(sitesProvider);
      final api = ref.read(cmsApiProvider);

      final futures = sites.map((site) => api
          .search(site: site, keyword: trimmed)
          .catchError((_) =>
              VideoListResult(items: [], total: 0, pageCount: 1)));

      final results = await Future.wait(futures);
      return results.expand((r) => r.items).toList();
    });
  }

  void clear() {
    state = const AsyncValue.data([]);
  }
}

final searchProvider =
    AsyncNotifierProvider<SearchNotifier, List<VideoItem>>(
  SearchNotifier.new,
);

/// 搜索历史关键词列表
final searchHistoryProvider = Provider<List<String>>((ref) {
  final storage = ref.watch(searchHistoryStorageProvider);
  return storage.getAll();
});

/// 最近更新（取第一个 site 的第一页数据，不指定分类）
final latestUpdatesProvider = FutureProvider.autoDispose<List<VideoItem>>((ref) async {
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
