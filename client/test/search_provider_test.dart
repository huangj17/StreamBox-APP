import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/local/search_history_storage.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/video_item.dart';
import 'package:streambox/data/models/video_list_result.dart';
import 'package:streambox/data/sources/cms_api.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/search/providers/search_provider.dart';

void main() {
  test('快源先展示，慢源随后追加，保留来源身份和进度', () async {
    final api = _ControlledSearchApi();
    final container = _container(api, const [
      Site(key: 'fast', name: '快源', type: 3, api: 'https://fast.example/api'),
      Site(key: 'slow', name: '慢源', type: 3, api: 'https://slow.example/api'),
    ]);
    addTearDown(container.dispose);
    await container.read(searchProvider.future);
    final running = container.read(searchProvider.notifier).search('电影');
    api.complete('fast');
    await Future<void>.delayed(Duration.zero);
    expect(container.read(searchProvider).requireValue.single.siteKey, 'fast');
    expect(container.read(searchProgressProvider), (completed: 1, total: 2));
    api.complete('slow');
    await running;
    expect(container.read(searchProvider).requireValue.map((v) => v.siteKey), [
      'fast',
      'slow',
    ]);
    expect(container.read(searchProgressProvider), (completed: 2, total: 2));
  });

  test('离开搜索后迟到的响应不会写入已销毁状态', () async {
    final api = _ControlledSearchApi();
    final container = _container(api, const [
      Site(key: 'slow', name: '慢源', type: 3, api: 'https://slow.example/api'),
    ]);
    await container.read(searchProvider.future);
    final running = container.read(searchProvider.notifier).search('电影');
    container.dispose();
    api.complete('slow');
    await running;
  });

  test('a superseded search cannot overwrite the latest results', () async {
    final api = _FakeSearchApi();
    final container = _container(api, const [
      Site(
        key: 'searchable',
        name: 'Searchable',
        type: 3,
        api: 'https://search.example/api',
      ),
    ]);
    addTearDown(container.dispose);
    await container.read(searchProvider.future);

    final notifier = container.read(searchProvider.notifier);
    final slow = notifier.search('slow');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final fast = notifier.search('fast');
    await Future.wait([slow, fast]);

    final state = container.read(searchProvider).requireValue;
    expect(state.single.title, 'fast');
  });

  test('search skips sites marked as non-searchable', () async {
    final api = _FakeSearchApi();
    final container = _container(api, const [
      Site(
        key: 'enabled',
        name: 'Enabled',
        type: 3,
        api: 'https://enabled.example/api',
      ),
      Site(
        key: 'disabled',
        name: 'Disabled',
        type: 3,
        api: 'https://disabled.example/api',
        searchable: false,
      ),
    ]);
    addTearDown(container.dispose);
    await container.read(searchProvider.future);

    await container.read(searchProvider.notifier).search('query');

    expect(api.calledSites, ['enabled']);
  });
}

ProviderContainer _container(_FakeSearchApi api, List<Site> sites) {
  return ProviderContainer(
    overrides: [
      cmsApiProvider.overrideWithValue(api),
      sitesProvider.overrideWith((ref) => sites),
      searchSitesProvider.overrideWith((ref) => ref.watch(sitesProvider)),
      searchHistoryStorageProvider.overrideWithValue(_MemorySearchHistory()),
    ],
  );
}

class _FakeSearchApi extends CmsApi {
  _FakeSearchApi() : super(Dio());

  final calledSites = <String>[];

  @override
  Future<VideoListResult> search({
    required Site site,
    required String keyword,
    CancelToken? cancelToken,
  }) async {
    calledSites.add(site.key);
    await Future<void>.delayed(
      keyword == 'slow'
          ? const Duration(milliseconds: 80)
          : const Duration(milliseconds: 10),
    );
    return VideoListResult(
      items: [
        VideoItem(id: keyword, title: keyword, cover: '', siteKey: site.key),
      ],
      total: 1,
      pageCount: 1,
    );
  }
}

class _MemorySearchHistory extends SearchHistoryStorage {
  final _items = <String>[];

  @override
  List<String> getAll() => List.unmodifiable(_items);

  @override
  Future<void> add(String keyword) async {
    _items
      ..remove(keyword)
      ..insert(0, keyword);
  }
}

class _ControlledSearchApi extends _FakeSearchApi {
  final pending = <String, Completer<VideoListResult>>{};
  @override
  Future<VideoListResult> search({
    required Site site,
    required String keyword,
    CancelToken? cancelToken,
  }) {
    return (pending[site.key] = Completer<VideoListResult>()).future;
  }

  void complete(String key) => pending[key]!.complete(
    VideoListResult(
      items: [VideoItem(id: '1', title: '同名电影', cover: '', siteKey: key)],
      total: 1,
      pageCount: 1,
    ),
  );
}
