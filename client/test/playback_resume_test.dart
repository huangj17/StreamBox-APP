import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/episode.dart';
import 'package:streambox/data/models/playback_resume.dart';

Episode ep(String name, {String url = 'https://media.example/video.m3u8'}) =>
    Episode(name: name, url: url);

void main() {
  test('匹配常见集数命名、前导零、全角字符和中文数字', () {
    for (final name in [
      '第5集',
      '第05集',
      ' 第 ５ 集 ',
      '第五集',
      '05',
      'EP005',
      'Episode 5',
    ]) {
      expect(
        matchingEpisodeIndex([ep('第1集'), ep('第05集')], name),
        1,
        reason: name,
      );
    }
    expect(matchingEpisodeIndex([ep('第12集')], '第十二集'), 0);
    expect(matchingEpisodeIndex([ep('第105集')], '第一百零五集'), 0);
    expect(matchingEpisodeIndex([ep('第1005集')], '第一千零五集'), 0);
  });

  test('列表顺序与长度不同仍按集数名称定位，并搜索其他线路', () {
    final groups = [
      [ep('第9集'), ep('第1集')],
      [ep('第6集'), ep('EP5'), ep('第2集')],
    ];
    expect(matchingEpisodeLocation(groups, '第05集'), (
      groupIndex: 1,
      episodeIndex: 1,
    ));
    expect(
      matchingEpisodeLocation(
        [
          [ep('第5集')],
          [ep('EP5')],
        ],
        '第五集',
        preferredGroupIndex: 1,
      ),
      (groupIndex: 1, episodeIndex: 0),
    );
  });

  test('预告、上下集、不同季和合并集数不会误匹配', () {
    for (final name in ['第5集预告', '第5集(上)', '第5-6集', 'S02E05']) {
      expect(
        matchingEpisodeIndex([ep('第5集'), ep('第5集(下)'), ep('S01E05')], name),
        isNull,
      );
    }
    expect(matchingEpisodeIndex([ep('特别篇')], ' 特别篇 '), 0);
  });

  test('缺集、不可播放与重名歧义返回失败，不按索引夹取', () {
    expect(matchingEpisodeIndex([ep('第1集')], '第5集'), isNull);
    expect(matchingEpisodeIndex([ep('第5集', url: '')], '第5集'), isNull);
    expect(matchingEpisodeIndex([ep('EP5'), ep('EP5')], '第5集'), isNull);
    expect(matchingEpisodeIndex([ep('第5集')], ''), isNull);
    expect(
      matchingEpisodeIndex([ep('第5集')], '第5集', playable: (_) => false),
      isNull,
    );
    final huge = List.filled(100, '9').join();
    expect(matchingEpisodeIndex([ep('第$huge集')], 'EP$huge'), isNull);
  });

  test('跨源重新定位保留播放进度并更新名称与索引', () {
    const resume = PlaybackResume(
      episodeName: '第05集',
      groupIndex: 2,
      episodeIndex: 4,
      positionMs: 123456,
    );
    final moved = resume.at((groupIndex: 1, episodeIndex: 0), 'EP5');
    expect(moved.positionMs, 123456);
    expect(moved.episodeName, 'EP5');
    expect(moved.groupIndex, 1);
    expect(moved.episodeIndex, 0);
  });
}
