import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/source_health.dart';
import 'package:streambox/data/sources/source_health_checker.dart';
import 'package:streambox/features/source/providers/source_provider.dart';

void main() {
  test('前台恢复只刷新已过期的片源状态', () async {
    final checker = _CountingChecker();
    final notifier = SourceHealthNotifier(checker);
    addTearDown(notifier.dispose);
    notifier.setSources(const ['https://cms.example/api.php/provide/vod/']);

    await notifier.refreshAll();
    expect(checker.checkCount, 1);

    await notifier.refreshStale(maxAge: const Duration(hours: 1));
    expect(checker.checkCount, 1, reason: '刚检测完成的片源不应因普通切窗重复请求');

    await notifier.refreshStale(maxAge: Duration.zero);
    expect(checker.checkCount, 2, reason: '超过允许时效后仍应重新检测');
  });
}

class _CountingChecker extends SourceHealthChecker {
  int checkCount = 0;

  _CountingChecker() : super(Dio());

  @override
  Future<SourceHealth> check(String sourceUrl) async {
    checkCount += 1;
    return SourceHealth.available();
  }
}
