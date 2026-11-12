import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/video_item.dart';
import 'package:streambox/data/models/video_aggregation.dart';

VideoItem video(
  String site, {
  String title = '沙丘',
  String? year = '2021',
  String? type = '电影',
  String? douban,
}) => VideoItem(
  id: '1',
  title: title,
  cover: '',
  siteKey: site,
  year: year,
  mediaType: type,
  doubanId: douban,
);

void main() {
  test('同一作品聚合，保留原始来源并去掉站内重复结果', () {
    final result = aggregateVideos([
      video('a'),
      video('b', title: ' 沙 丘（1080P）'),
      video('a'),
    ]);
    expect(result, hasLength(1));
    expect(result.single.sources.map(videoSourceIdentity), ['a:1', 'b:1']);
    expect(result.single.aggregateKey, 'a:1');
  });

  test('重拍、不同季、不同类型与冲突作品 ID 都不合并', () {
    expect(
      aggregateVideos([video('a'), video('b', year: '1984')]),
      hasLength(2),
    );
    expect(
      aggregateVideos([
        video('a', title: '庆余年 第一季'),
        video('b', title: '庆余年 第二季'),
      ]),
      hasLength(2),
    );
    expect(
      aggregateVideos([video('a'), video('b', type: '电视剧')]),
      hasLength(2),
    );
    expect(
      aggregateVideos([video('a', douban: '100'), video('b', douban: '200')]),
      hasLength(2),
    );
  });

  test('未知年份仅在可靠作品 ID 一致时跨站合并', () {
    expect(
      aggregateVideos([video('a', year: null), video('b', year: null)]),
      hasLength(2),
    );
    expect(
      aggregateVideos([
        video('a', year: null, douban: '100'),
        video('b', year: null, douban: '100'),
      ]),
      hasLength(1),
    );
    expect(
      aggregateVideos([
        video('a', year: null, douban: '0'),
        video('b', year: null, douban: '0'),
      ]),
      hasLength(2),
    );
  });

  test('缺失元数据不能桥接冲突类型，歧义项保留独立卡片', () {
    final result = aggregateVideos([
      video('a'),
      video('b', type: '电视剧'),
      video('c', type: null),
    ]);
    expect(result, hasLength(3));
  });

  test('推荐代表变化时卡片身份与列表位置保持稳定', () {
    final first = aggregateVideos([video('a'), video('b', title: '另一部电影')]);
    final next = aggregateVideos([
      video('a'),
      video('b', title: '另一部电影'),
      video('c'),
    ], compareSources: (a, b) => b.siteKey.compareTo(a.siteKey));
    expect(next.first.siteKey, 'c');
    expect(next.map((v) => v.aggregateKey), first.map((v) => v.aggregateKey));
  });

  test('CMS 列表解析保留作品 ID 和类型，空片名不聚合', () {
    final parsed = VideoItem.fromJson({
      'vod_id': 1,
      'vod_name': '沙丘',
      'vod_year': '2021',
      'type_name': '科幻片',
      'vod_douban_id': 100,
    }, siteKey: 'a');
    expect(parsed.mediaType, '科幻片');
    expect(parsed.doubanId, '100');
    expect(
      aggregateVideos([video('a', title: ''), video('b', title: '')]),
      hasLength(2),
    );
  });

  int bySite(VideoItem a, VideoItem b) => a.siteKey.compareTo(b.siteKey);
  List<String> describe(List<VideoItem> groups) => [
    for (final g in groups)
      '${g.aggregateKey}|${g.siteKey}:${g.id}|'
          '${g.sources.map(videoSourceIdentity).join(',')}',
  ];

  test('与逐对比较的参照实现结果一致，分批加入与一次加入一致', () {
    final random = Random(7);
    for (var round = 0; round < 200; round++) {
      final items = _randomVideos(random, 1 + random.nextInt(60));
      final expected = describe(
        _referenceAggregate(items, compareSources: bySite),
      );
      expect(
        describe(aggregateVideos(items, compareSources: bySite)),
        expected,
      );
      final aggregator = VideoAggregator(compareSources: bySite);
      var start = 0;
      while (start < items.length) {
        final end = min(items.length, start + 1 + random.nextInt(8));
        aggregator.addAll(items.sublist(start, end));
        start = end;
      }
      expect(describe(aggregator.snapshot()), expected);
    }
  });

  test('大量片源的聚合保持近线性耗时', () {
    final items = [
      for (var site = 0; site < 80; site++)
        for (var i = 0; i < 20; i++)
          video(
            's$site',
            title: '斗罗大陆 ${i % 5}',
            year: '${2018 + (site + i) % 6}',
          ).withId('$i'),
    ];
    final watch = Stopwatch()..start();
    final aggregator = VideoAggregator(compareSources: bySite);
    for (var site = 0; site < 80; site++) {
      aggregator.addAll(items.sublist(site * 20, site * 20 + 20));
      aggregator.snapshot();
    }
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}

extension on VideoItem {
  VideoItem withId(String id) => VideoItem(
    id: id,
    title: title,
    cover: cover,
    siteKey: siteKey,
    year: year,
    mediaType: mediaType,
    doubanId: doubanId,
  );
}

List<VideoItem> _randomVideos(Random random, int count) {
  const titles = ['沙丘', '沙 丘（1080P）', '沙丘2', '', '庆余年 第一季', '庆余年第一季'];
  const years = [null, '2021', '2024', 'abc'];
  const types = [null, '电影', '电视剧', '动画片', '综艺'];
  const doubans = [null, null, '100', '200', '0'];
  T pick<T>(List<T> values) => values[random.nextInt(values.length)];
  return [
    for (var i = 0; i < count; i++)
      VideoItem(
        id: '${random.nextInt(4)}',
        title: pick(titles),
        cover: '',
        siteKey: 's${random.nextInt(6)}',
        year: pick(years),
        mediaType: pick(types),
        doubanId: pick(doubans),
      ),
  ];
}

String _refTitle(String title) => title
    .toLowerCase()
    .replaceAll(
      RegExp(
        r'[（(\[]\s*(?:4k|1080p|720p|2160p|高清|超清)\s*[）)\]]',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

String? _refYear(String? value) {
  final year = value?.trim();
  return year != null && RegExp(r'^(19|20)\d{2}$').hasMatch(year) ? year : null;
}

String? _refDouban(String? value) {
  final id = value?.trim();
  return id != null && RegExp(r'^[1-9]\d*$').hasMatch(id) ? id : null;
}

String? _refKind(VideoItem item) {
  final type = '${item.mediaType ?? ''} ${item.category ?? ''}';
  if (RegExp(r'短剧').hasMatch(type)) return 'short';
  if (RegExp(r'动漫|动画|卡通').hasMatch(type)) return 'animation';
  if (RegExp(r'综艺').hasMatch(type)) return 'variety';
  if (RegExp(r'电视剧|连续剧|国产剧|港剧|香港剧|韩剧|日剧|美剧|欧美剧|台剧|海外剧').hasMatch(type)) {
    return 'series';
  }
  if (RegExp(r'电影|片').hasMatch(type)) return 'movie';
  return null;
}

bool _refCompatible(VideoItem a, VideoItem b) {
  final title = _refTitle(a.title);
  if (title.isEmpty || title != _refTitle(b.title)) return false;
  final ay = _refYear(a.year), by = _refYear(b.year);
  if (ay != null && by != null && ay != by) return false;
  final ak = _refKind(a), bk = _refKind(b);
  if (ak != null && bk != null && ak != bk) return false;
  final ad = _refDouban(a.doubanId), bd = _refDouban(b.doubanId);
  return ad == null || bd == null || ad == bd;
}

bool _refSameWork(VideoItem a, VideoItem b) {
  if (videoSourceIdentity(a) == videoSourceIdentity(b)) return true;
  if (!_refCompatible(a, b)) return false;
  final ad = _refDouban(a.doubanId), bd = _refDouban(b.doubanId);
  if (ad != null && ad == bd) return true;
  final ay = _refYear(a.year), by = _refYear(b.year);
  return ay != null && ay == by;
}

/// The original pairwise implementation, kept as the behavioural oracle.
List<VideoItem> _referenceAggregate(
  List<VideoItem> items, {
  int Function(VideoItem, VideoItem)? compareSources,
}) {
  final seen = <String>{};
  final groups = <List<VideoItem>>[];
  for (final item in items) {
    if (!seen.add(videoSourceIdentity(item))) continue;
    final matches = groups
        .where(
          (group) =>
              group.any((v) => _refSameWork(v, item)) &&
              group.every((v) => _refCompatible(v, item)),
        )
        .toList();
    if (matches.length == 1) {
      matches.single.add(item);
    } else {
      groups.add([item]);
    }
  }
  return List.unmodifiable(
    groups.map((group) {
      final ordered = List<VideoItem>.of(group);
      if (compareSources != null) ordered.sort(compareSources);
      return ordered.first.withSources(
        videoSourceIdentity(group.first),
        ordered,
      );
    }),
  );
}
