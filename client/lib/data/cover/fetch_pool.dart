import 'dart:async';
import 'dart:collection';

/// 简单并发限流器：同时最多 [maxConcurrent] 个任务在跑，多余的排队。
///
/// 用于控制封面三方查询的并发：列表页快速滚动时不会瞬间把 TMDB/豆瓣打爆。
class FetchPool {
  final int maxConcurrent;
  int _inFlight = 0;
  final Queue<Completer<void>> _queue = Queue<Completer<void>>();

  FetchPool({this.maxConcurrent = 3});

  Future<T> run<T>(Future<T> Function() task) async {
    if (_inFlight >= maxConcurrent) {
      final c = Completer<void>();
      _queue.add(c);
      await c.future;
    }
    _inFlight++;
    try {
      return await task();
    } finally {
      _inFlight--;
      if (_queue.isNotEmpty) {
        _queue.removeFirst().complete();
      }
    }
  }
}
