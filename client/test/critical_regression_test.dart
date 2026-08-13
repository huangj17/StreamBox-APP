import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/category.dart';
import 'package:streambox/data/models/cms_video_detail.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/source_config.dart';
import 'package:streambox/data/repositories/home_repository.dart';
import 'package:streambox/data/sources/cms_api.dart';

void main() {
  group('JAR Bridge identity', () {
    test('ordinary TVBox type 4 is not treated as a reachable Bridge', () {
      final site = Site.fromJson({
        'key': 'jar',
        'name': '普通 JAR',
        'type': 4,
        'api': 'csp_Test',
      });

      expect(site.isBridge, isFalse);
      expect(SourceConfig(sites: [site]).cmsSites, isEmpty);
    });

    test('only sites discovered from Bridge carry Bridge identity', () {
      final site = Site.fromBridge(
        bridgeUrl: 'http://127.0.0.1:9978',
        key: 'test',
        name: 'Test',
        apiPath: '/api/test',
      );

      expect(site.isBridge, isTrue);
      expect(site.api, 'http://127.0.0.1:9978/api/test');
    });
  });

  test('parse flag and source flag stay aligned after quality sorting', () {
    final detail = CmsVideoDetail.fromJson({
      'vod_id': 1,
      'vod_name': 'Test',
      'vod_play_from': '360P\$\$\$1080P',
      'vod_play_url': '低清\$raw-low\$\$\$高清\$raw-high',
      'parse': '0\$\$\$1',
    });

    final high = detail.episodeGroups.first.single;
    final low = detail.episodeGroups.last.single;
    expect(high.sourceFlag, '1080P');
    expect(high.requiresResolve, isTrue);
    expect(low.sourceFlag, '360P');
    expect(low.requiresResolve, isFalse);
  });

  test('same-name categories from different sites are both retained', () async {
    const first = Site(
      key: 'one',
      name: 'One',
      type: 3,
      api: 'https://one.example/api',
    );
    const second = Site(
      key: 'two',
      name: 'Two',
      type: 3,
      api: 'https://two.example/api',
    );
    final api = _FakeCmsApi({
      'one': const [
        Category(
          id: 'parent',
          name: '电影',
          siteKey: 'one',
          type: CategoryType.dynamic,
        ),
        Category(
          id: 'action',
          name: '动作片',
          siteKey: 'one',
          type: CategoryType.dynamic,
          typePid: 1,
        ),
      ],
      'two': const [
        Category(
          id: 'movie',
          name: '动作片',
          siteKey: 'two',
          type: CategoryType.dynamic,
        ),
      ],
    });

    final categories = await HomeRepository(api).getCategories([first, second]);
    final dynamicCategories = categories
        .where((category) => category.type == CategoryType.dynamic)
        .toList();

    expect(dynamicCategories, hasLength(2));
    expect(dynamicCategories.map((category) => category.siteKey).toSet(), {
      'one',
      'two',
    });
  });
}

class _FakeCmsApi extends CmsApi {
  final Map<String, List<Category>> categories;

  _FakeCmsApi(this.categories) : super(Dio());

  @override
  Future<List<Category>> fetchCategories(
    Site site, {
    CancelToken? cancelToken,
  }) async => categories[site.key] ?? const [];
}
