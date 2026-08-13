import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/features/player/player_buffering.dart';

void main() {
  group('continuousBufferedEnd', () {
    test('只返回包含播放位置的连续缓存段', () {
      final end = continuousBufferedEnd(
        position: const Duration(seconds: 12),
        ranges: const [
          PlaybackBufferRange(start: Duration.zero, end: Duration(seconds: 20)),
          PlaybackBufferRange(
            start: Duration(seconds: 40),
            end: Duration(seconds: 55),
          ),
        ],
      );

      expect(end, const Duration(seconds: 20));
    });

    test('seek 到未缓存空洞时退回当前播放位置', () {
      final end = continuousBufferedEnd(
        position: const Duration(seconds: 30),
        ranges: const [
          PlaybackBufferRange(start: Duration.zero, end: Duration(seconds: 20)),
          PlaybackBufferRange(
            start: Duration(seconds: 40),
            end: Duration(seconds: 55),
          ),
        ],
      );

      expect(end, const Duration(seconds: 30));
    });

    test('合并相邻的缓存分片', () {
      final end = continuousBufferedEnd(
        position: const Duration(seconds: 10),
        ranges: const [
          PlaybackBufferRange(start: Duration.zero, end: Duration(seconds: 20)),
          PlaybackBufferRange(
            start: Duration(milliseconds: 20100),
            end: Duration(seconds: 30),
          ),
        ],
      );

      expect(end, const Duration(seconds: 30));
    });
  });

  group('PlaybackProgressEvidence', () {
    test('duration 或 playing 本身不会构成首帧证据', () {
      final evidence = PlaybackProgressEvidence()
        ..arm(const Duration(seconds: 10));

      expect(evidence.isArmed, isTrue);
      expect(evidence.observe(const Duration(seconds: 10)), isFalse);
      expect(evidence.isArmed, isTrue);
    });

    test('seek 跳转只建立基线，后续时钟推进才确认恢复', () {
      final evidence = PlaybackProgressEvidence()..arm(Duration.zero);

      evidence.expect(const Duration(minutes: 20));
      expect(evidence.observe(const Duration(seconds: 5)), isFalse);
      expect(evidence.observe(const Duration(minutes: 20)), isFalse);
      expect(
        evidence.observe(const Duration(minutes: 20, milliseconds: 150)),
        isFalse,
      );
      expect(
        evidence.observe(const Duration(minutes: 20, milliseconds: 300)),
        isTrue,
      );
      expect(evidence.isArmed, isFalse);
    });

    test('单次大幅位置跳变不会被当成连续播放', () {
      final evidence = PlaybackProgressEvidence()..arm(Duration.zero);

      expect(evidence.observe(Duration.zero), isFalse);
      expect(evidence.observe(const Duration(seconds: 8)), isFalse);
      expect(
        evidence.observe(const Duration(seconds: 8, milliseconds: 150)),
        isFalse,
      );
      expect(
        evidence.observe(const Duration(seconds: 8, milliseconds: 300)),
        isTrue,
      );
    });
  });

  group('PlaybackProgressState', () {
    test('buffer ahead 不会小于零并按秒数分级', () {
      const critical = PlaybackProgressState(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 2),
        buffered: Duration(seconds: 18),
      );
      const low = PlaybackProgressState(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 2),
        buffered: Duration(seconds: 30),
      );
      const healthy = PlaybackProgressState(
        position: Duration(seconds: 20),
        duration: Duration(minutes: 2),
        buffered: Duration(seconds: 40),
      );
      const nearEnd = PlaybackProgressState(
        position: Duration(seconds: 118),
        duration: Duration(minutes: 2),
        buffered: Duration(minutes: 2),
      );

      expect(critical.bufferAhead, Duration.zero);
      expect(critical.bufferHealth, PlaybackBufferHealth.critical);
      expect(low.bufferHealth, PlaybackBufferHealth.low);
      expect(healthy.bufferHealth, PlaybackBufferHealth.healthy);
      expect(nearEnd.bufferHealth, PlaybackBufferHealth.healthy);
    });
  });

  group('PlaybackBufferTuning', () {
    test('默认、倍速和高码率策略受内存上限约束', () {
      final normal = PlaybackBufferTuning.forPlayback();
      final fast = PlaybackBufferTuning.forPlayback(playbackRate: 2.0);
      final demanding = PlaybackBufferTuning.forPlayback(
        playbackRate: 2.0,
        bitrate: 20 * 1000 * 1000,
      );

      expect(
        normal,
        const PlaybackBufferTuning(readaheadSeconds: 20, cacheSeconds: 30),
      );
      expect(fast.readaheadSeconds, 30);
      expect(demanding.readaheadSeconds, lessThanOrEqualTo(27));
      expect(demanding.cacheSeconds, lessThanOrEqualTo(37));
    });
  });

  test('PlaybackBufferMetrics 记录首帧、重缓冲和最低余量', () {
    final metrics = PlaybackBufferMetrics();
    final started = DateTime(2026, 1, 1);
    metrics.reset(started);
    metrics.markFirstFrame(started.add(const Duration(seconds: 1)));
    metrics.onBufferingChanged(true, started.add(const Duration(seconds: 5)));
    metrics.onBufferingChanged(false, started.add(const Duration(seconds: 8)));
    metrics.observeBufferAhead(const Duration(seconds: 20));
    metrics.observeBufferAhead(const Duration(seconds: 10));

    final snapshot = metrics.snapshot(started.add(const Duration(seconds: 9)));
    expect(snapshot.firstFrameLatency, const Duration(seconds: 1));
    expect(snapshot.rebufferCount, 1);
    expect(snapshot.totalRebufferDuration, const Duration(seconds: 3));
    expect(snapshot.minimumBufferAhead, const Duration(seconds: 10));
  });
}
