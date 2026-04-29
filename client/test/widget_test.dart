import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/cms_video_detail.dart';

/// CMS 播放地址解析测试
///
/// 原来的 smoke test 依赖 Hive + 5 个 storage override 才能启动 HomeScreen，
/// 成本远大于价值。换成真正有业务价值的纯单元测试，覆盖 CMS 播放地址格式：
/// `名称$url#名称$url$$$线路2$url#...`
void main() {
  group('CmsVideoDetail', () {
    test('解析单线路多集', () {
      final detail = CmsVideoDetail(
        vodId: 1,
        vodName: 'Test',
        vodPic: '',
        vodContent: '',
        vodPlayFrom: 'source1',
        vodPlayUrl: '第1集\$http://a.com/1.m3u8#第2集\$http://a.com/2.m3u8',
      );
      final groups = detail.episodeGroups;
      expect(groups.length, 1);
      expect(groups[0].length, 2);
      expect(groups[0][0].name, '第1集');
      expect(groups[0][0].url, 'http://a.com/1.m3u8');
      expect(groups[0][1].name, '第2集');
      expect(groups[0][1].url, 'http://a.com/2.m3u8');
    });

    test('解析多线路（\$\$\$ 分隔）', () {
      final detail = CmsVideoDetail(
        vodId: 1,
        vodName: 'Test',
        vodPic: '',
        vodContent: '',
        vodPlayFrom: 'source1\$\$\$source2',
        vodPlayUrl:
            '第1集\$http://a.com/1.m3u8\$\$\$第1集\$http://b.com/1.m3u8',
      );
      expect(detail.episodeGroups.length, 2);
      expect(detail.sourceNames.length, 2);
    });

    test('URL 内含 \$ 时用首个 \$ 作为名称/地址分隔', () {
      final detail = CmsVideoDetail(
        vodId: 1,
        vodName: 'Test',
        vodPic: '',
        vodContent: '',
        vodPlayFrom: 'source1',
        vodPlayUrl: '第1集\$http://a.com/play?token=x\$y&n=1',
      );
      final ep = detail.episodeGroups[0][0];
      expect(ep.name, '第1集');
      expect(ep.url, 'http://a.com/play?token=x\$y&n=1');
    });

    test('按画质排序（1080P 排到 360P 前面）', () {
      final detail = CmsVideoDetail(
        vodId: 1,
        vodName: 'Test',
        vodPic: '',
        vodContent: '',
        vodPlayFrom: '360P\$\$\$1080P',
        vodPlayUrl: 'a\$http://a.com/1\$\$\$b\$http://b.com/1',
      );
      // 画质更高的线路应排在前面
      expect(detail.sourceNames.first.contains('1080P'), true);
      expect(detail.episodeGroups[0][0].url, 'http://b.com/1');
    });

    test('空 vodPlayUrl 返回空列表', () {
      final detail = CmsVideoDetail(
        vodId: 1,
        vodName: 'Test',
        vodPic: '',
        vodContent: '',
        vodPlayFrom: '',
        vodPlayUrl: '',
      );
      expect(detail.episodeGroups, isEmpty);
      expect(detail.sourceNames, isEmpty);
    });
  });
}
