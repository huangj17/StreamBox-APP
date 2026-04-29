import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/cover/fetch_pool.dart';
import 'package:streambox/widgets/letter_poster.dart';

/// 封面补全相关逻辑的单元测试：字母提取、稳定配色、并发池。
void main() {
  group('LetterPoster.extractLetter', () {
    test('中文标题取首个汉字', () {
      expect(LetterPoster.extractLetter('庆余年'), '庆');
      expect(LetterPoster.extractLetter('流浪地球 2'), '流');
    });

    test('英文标题首字母大写', () {
      expect(LetterPoster.extractLetter('breaking bad'), 'B');
      expect(LetterPoster.extractLetter('Attack on Titan'), 'A');
    });

    test('首尾空格被修剪', () {
      expect(LetterPoster.extractLetter('   Foo'), 'F');
    });

    test('空字符串回退为问号', () {
      expect(LetterPoster.extractLetter(''), '?');
      expect(LetterPoster.extractLetter('   '), '?');
    });

    test('emoji / 组合字形保持单字素', () {
      // 👨‍👩‍👧 是 ZWJ 组合字素；characters.first 应返回整个序列
      final letter = LetterPoster.extractLetter('👨‍👩‍👧 家庭');
      expect(letter.isNotEmpty, true);
    });
  });

  group('LetterPoster.gradientFor', () {
    test('同 seed 返回同渐变（稳定）', () {
      final a = LetterPoster.gradientFor('site1:vod42');
      final b = LetterPoster.gradientFor('site1:vod42');
      expect(a, equals(b));
    });

    test('不同 seed 有机会落到不同渐变', () {
      final seeds = List.generate(30, (i) => 'seed_$i');
      final distinct = seeds.map(LetterPoster.gradientFor).toSet();
      // 12 组渐变库，30 个 seed 至少应命中 >1 组
      expect(distinct.length, greaterThan(1));
    });

    test('渐变始终为双色', () {
      for (var i = 0; i < 20; i++) {
        final colors = LetterPoster.gradientFor('s$i');
        expect(colors.length, 2);
      }
    });
  });

  group('FetchPool', () {
    test('同时在飞的任务数不超过 maxConcurrent', () async {
      final pool = FetchPool(maxConcurrent: 2);
      var active = 0;
      var peak = 0;

      Future<int> task(int i) async {
        active++;
        if (active > peak) peak = active;
        await Future.delayed(const Duration(milliseconds: 30));
        active--;
        return i;
      }

      final futures =
          List.generate(6, (i) => pool.run(() => task(i)));
      final results = await Future.wait(futures);

      expect(results, [0, 1, 2, 3, 4, 5]);
      expect(peak, lessThanOrEqualTo(2));
    });

    test('任务抛异常后其它任务仍能正常调度', () async {
      final pool = FetchPool(maxConcurrent: 1);
      final outcomes = <String>[];

      final f1 = pool.run<void>(() async {
        throw StateError('boom');
      }).catchError((_) {
        outcomes.add('caught');
      });
      final f2 = pool.run<void>(() async {
        outcomes.add('ran');
      });

      await Future.wait([f1, f2]);
      expect(outcomes, ['caught', 'ran']);
    });

    test('空闲时立即执行不排队', () async {
      final pool = FetchPool(maxConcurrent: 3);
      final start = DateTime.now();
      await pool.run(() async => 1);
      final elapsed = DateTime.now().difference(start);
      expect(elapsed.inMilliseconds, lessThan(30));
    });
  });
}
