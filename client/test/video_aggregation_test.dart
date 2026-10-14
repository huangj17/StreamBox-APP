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
}
