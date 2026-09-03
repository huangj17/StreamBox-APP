import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/source_health.dart';
import 'package:streambox/data/sources/source_health_checker.dart';
import 'package:streambox/features/source/providers/source_provider.dart';

void main() {
  for (final target in ['cms', 'config', 'gateway', 'media']) {
    test('总超时会取消实际 $target 请求，不只结束界面等待', () async {
      final adapter = _CancellationAdapter(media: target == 'media');
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final checker = SourceHealthChecker(
        dio,
        resolveHost: (_) async => [InternetAddress('203.0.113.10')],
      );
      final notifier = SourceHealthNotifier(
        checker,
        checkTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(notifier.dispose);
      final url = switch (target) {
        'config' => 'https://config.example/box.json',
        'gateway' => 'https://gateway.example:9978',
        _ => 'https://cms.example/api.php',
      };
      notifier.setSources([url]);
      await notifier.refreshAll();
      await _flush();
      expect(adapter.cancelled, isTrue);
      expect(notifier.state[url]!.message, contains('检测超时'));
      if (target == 'media') expect(adapter.paths.last, '/segment.ts');
    });
  }

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

  test('六路同时检测，任意任务先完成就补位，不等待最慢项', () async {
    final checker = _ControlledChecker();
    final notifier = SourceHealthNotifier(checker, cmsOnly: true);
    addTearDown(notifier.dispose);
    final urls = List.generate(9, (i) => 'source-$i');
    notifier.setSources(urls);
    final refresh = notifier.refreshAll();
    expect(checker.calls.map((c) => c.url), urls.take(6));
    expect(checker.cmsChecks, 6);
    expect(notifier.state[urls[6]]!.status, SourceHealthStatus.queued);

    checker.calls[2].result.complete(SourceHealth.available());
    await _flush();
    expect(checker.calls.last.url, urls[6]);
    expect(checker.calls[0].result.isCompleted, isFalse);
    expect(notifier.state[urls[2]]!.status, SourceHealthStatus.available);
    expect(notifier.state[urls[6]]!.status, SourceHealthStatus.checking);

    await checker.finishAll();
    await refresh;
    expect(checker.calls, hasLength(9));
    expect(notifier.state.values.every((h) => !h.isPending), isTrue);
  });

  test('重复请求共享任务；检测中新加片源只补充新项，不重跑整个列表', () async {
    final checker = _ControlledChecker();
    final notifier = SourceHealthNotifier(checker, maxConcurrentChecks: 2);
    addTearDown(notifier.dispose);
    notifier.setSources(['a', 'b', 'c']);
    final all = notifier.refreshAll();
    final duplicate = notifier.refreshUrls(['a', 'c', 'c']);
    var duplicateDone = false;
    unawaited(duplicate.then((_) => duplicateDone = true));
    notifier.setSources(['a', 'b', 'c', 'd']);
    expect(checker.calls.map((c) => c.url), ['a', 'b']);
    expect(duplicateDone, isFalse);
    await checker.finishAll();
    await Future.wait([all, duplicate]);
    expect(checker.calls.map((c) => c.url), ['a', 'b', 'c', 'd']);
  });

  testWidgets('单源总超时取消请求并立即补位，迟到结果不覆盖超时状态', (tester) async {
    final checker = _ControlledChecker();
    final notifier = SourceHealthNotifier(checker, maxConcurrentChecks: 1);
    addTearDown(notifier.dispose);
    notifier.setSources(['slow', 'next']);
    final refresh = notifier.refreshAll();
    await tester.pump(const Duration(seconds: 12));
    expect(checker.calls.first.token!.isCancelled, isTrue);
    expect(notifier.state['slow']!.message, contains('12 秒'));
    expect(checker.calls.last.url, 'next');
    checker.calls.first.result.complete(SourceHealth.available());
    checker.calls.last.result.complete(SourceHealth.available());
    await tester.pump();
    await refresh;
    expect(notifier.state['slow']!.status, SourceHealthStatus.unavailable);
    expect(notifier.state['next']!.status, SourceHealthStatus.available);
    notifier.setSources([]);
  });

  test('移除时取消并释放位置，同 URL 重新添加不接收旧任务结果', () async {
    final checker = _ControlledChecker();
    final notifier = SourceHealthNotifier(checker, maxConcurrentChecks: 1);
    addTearDown(notifier.dispose);
    notifier.setSources(['same']);
    final old = notifier.refreshAll();
    final first = checker.calls.single;
    notifier.setSources([]);
    expect(first.token!.isCancelled, isTrue);
    notifier.setSources(['same']);
    final latest = notifier.refreshAll();
    await _flush();
    expect(checker.calls, hasLength(2));
    first.result.complete(SourceHealth.available());
    await _flush();
    expect(notifier.state['same']!.status, SourceHealthStatus.checking);
    checker.calls.last.result.complete(SourceHealth.unverified(message: '新结果'));
    await Future.wait([old, latest]);
    expect(notifier.state['same']!.message, '新结果');
  });

  test('一个检测抛出异常不影响后续任务，销毁时取消运行和等待任务', () async {
    final checker = _ControlledChecker();
    final notifier = SourceHealthNotifier(checker, maxConcurrentChecks: 1);
    notifier.setSources(['bad', 'running', 'queued']);
    final refresh = notifier.refreshAll();
    checker.calls.first.result.completeError(StateError('broken'));
    await _flush();
    expect(notifier.state['bad']!.status, SourceHealthStatus.unavailable);
    expect(checker.calls.last.url, 'running');
    notifier.dispose();
    await refresh;
    expect(checker.calls.last.token!.isCancelled, isTrue);
    checker.calls.last.result.complete(SourceHealth.available());
    await _flush();
    expect(checker.calls, hasLength(2));
  });

  testWidgets('手动检测完成后不会被启动定时器重复检测', (tester) async {
    final checker = _CountingChecker();
    final notifier = SourceHealthNotifier(checker);
    addTearDown(notifier.dispose);
    notifier.setSources(['a']);
    final refresh = notifier.refreshAll();
    await tester.pump();
    await refresh;
    await tester.pump(SourceHealthNotifier.startupDelay);
    expect(checker.checkCount, 1);
    notifier.setSources([]);
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _PendingCheck {
  final String url;
  final CancelToken? token;
  final result = Completer<SourceHealth>();
  _PendingCheck(this.url, this.token);
}

class _ControlledChecker extends SourceHealthChecker {
  final calls = <_PendingCheck>[];
  int cmsChecks = 0;
  _ControlledChecker() : super(Dio());

  @override
  Future<SourceHealth> check(String sourceUrl, {CancelToken? cancelToken}) {
    final call = _PendingCheck(sourceUrl, cancelToken);
    calls.add(call);
    return call.result.future;
  }

  @override
  Future<SourceHealth> checkCms(String sourceUrl, {CancelToken? cancelToken}) {
    cmsChecks++;
    return check(sourceUrl, cancelToken: cancelToken);
  }

  Future<void> finishAll() async {
    while (calls.any((call) => !call.result.isCompleted)) {
      for (final call in calls.toList()) {
        if (!call.result.isCompleted) {
          call.result.complete(SourceHealth.available());
        }
      }
      await _flush();
    }
  }
}

class _CountingChecker extends SourceHealthChecker {
  int checkCount = 0;

  _CountingChecker() : super(Dio());

  @override
  Future<SourceHealth> check(
    String sourceUrl, {
    CancelToken? cancelToken,
  }) async {
    checkCount += 1;
    return SourceHealth.available();
  }
}

class _CancellationAdapter implements HttpClientAdapter {
  final bool media;
  bool cancelled = false;
  final paths = <String>[];
  _CancellationAdapter({required this.media});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    if (media && options.uri.host == 'cms.example') {
      return ResponseBody.fromString(
        r'{"list":[{"vod_id":1,"vod_name":"Test","vod_play_from":"line","vod_play_url":"第1集$https://media.example/index.m3u8"}]}',
        200,
      );
    }
    if (media && options.uri.path == '/index.m3u8') {
      return ResponseBody.fromString('#EXTM3U\n#EXTINF:3,\nsegment.ts\n', 200);
    }
    await cancelFuture;
    cancelled = true;
    return ResponseBody.fromString('', 499);
  }

  @override
  void close({bool force = false}) {}
}
