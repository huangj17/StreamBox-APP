import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/cover/cover_resolver.dart';
import 'package:streambox/data/cover/providers.dart';
import 'package:streambox/data/models/category.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/video_item.dart';
import 'package:streambox/data/models/video_list_result.dart';
import 'package:streambox/data/sources/cms_api.dart';
import 'package:streambox/features/home/category_detail_screen.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/home/widgets/hero_banner.dart';
import 'package:streambox/widgets/resolvable_cover.dart';

void main() {
  testWidgets('hero clamps its index when replacement items are shorter', (
    tester,
  ) async {
    final items = ValueNotifier<List<VideoItem>>(
      List.generate(5, (index) => _video('$index')),
    );
    addTearDown(items.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ValueListenableBuilder<List<VideoItem>>(
            valueListenable: items,
            builder: (context, value, _) => HeroBanner(
              items: value,
              autoPlayInterval: const Duration(milliseconds: 10),
              onItemFocused: (_) {},
              onItemSelected: (_) {},
              onItemPlay: (_) async {},
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 11));
    }

    items.value = [_video('replacement')];
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Title replacement'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an old cover lookup cannot replace a newer title cover', (
    tester,
  ) async {
    final resolver = _ControlledCoverResolver();
    final title = ValueNotifier<String>('old');
    addTearDown(title.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [coverResolverProvider.overrideWithValue(resolver)],
        child: MaterialApp(
          home: ValueListenableBuilder<String>(
            valueListenable: title,
            builder: (context, value, _) =>
                ResolvableCover(directUrl: '', title: value, seed: value),
          ),
        ),
      ),
    );
    title.value = 'new';
    await tester.pump();

    resolver.complete('new', 'https://images.example/new.jpg');
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .imageUrl,
      'https://images.example/new.jpg',
    );

    resolver.complete('old', 'https://images.example/old.jpg');
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .imageUrl,
      'https://images.example/new.jpg',
    );
  });

  testWidgets('category load failures show an explicit retry action', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cmsApiProvider.overrideWithValue(_FailingCmsApi())],
        child: const MaterialApp(
          home: CategoryDetailScreen(
            category: Category(
              id: 'movies',
              name: '电影',
              siteKey: 'site',
              type: CategoryType.dynamic,
            ),
            site: Site(
              key: 'site',
              name: 'Site',
              type: 3,
              api: 'https://cms.example/api',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('加载失败，请检查网络或片源状态'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('暂无内容'), findsNothing);
  });
}

VideoItem _video(String id) => VideoItem(
  id: id,
  title: 'Title $id',
  cover: 'https://images.example/$id.jpg',
  siteKey: 'site',
);

class _ControlledCoverResolver implements CoverResolver {
  final _completers = <String, Completer<ResolvedCover?>>{};

  @override
  Future<ResolvedCover?> resolve(String title, String? year) =>
      (_completers[title] ??= Completer<ResolvedCover?>()).future;

  void complete(String title, String url) {
    _completers[title]!.complete(ResolvedCover(url, 'test'));
  }
}

class _FailingCmsApi extends CmsApi {
  _FailingCmsApi() : super(Dio());

  @override
  Future<VideoListResult> fetchVideoList({
    required Site site,
    required String categoryId,
    int page = 1,
    String? year,
  }) => Future.error(StateError('offline'));
}
