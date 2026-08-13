import 'package:flutter/foundation.dart';

/// 与具体播放引擎无关的媒体时间区间。
@immutable
class PlaybackBufferRange {
  final Duration start;
  final Duration end;

  const PlaybackBufferRange({required this.start, required this.end});
}

/// 返回包含 [position] 的连续缓冲区间终点。
///
/// 播放器可能返回多个互不连续的 buffered range。直接取最大的 end 会把
/// 中间空洞也画成已缓存；这里仅合并包含播放位置且彼此相邻的区间。
Duration continuousBufferedEnd({
  required Duration position,
  required Iterable<PlaybackBufferRange> ranges,
  Duration mergeTolerance = const Duration(milliseconds: 250),
}) {
  final sorted = ranges.where((range) => range.end >= range.start).toList()
    ..sort((a, b) => a.start.compareTo(b.start));

  Duration? end;
  for (final range in sorted) {
    if (end == null) {
      if (range.start <= position && range.end >= position) {
        end = range.end;
      }
      continue;
    }

    if (range.start <= end + mergeTolerance) {
      if (range.end > end) end = range.end;
    } else {
      break;
    }
  }

  return end == null || end < position ? position : end;
}

enum PlaybackBufferHealth { unknown, critical, low, healthy }

/// 判断播放时钟是否在到达预期位置后继续推进。
///
/// duration、playing 以及 seek 导致的位置跳变都不算首帧证据；只有后续
/// 两次 100ms～2s 的连续推进才算播放恢复。
class PlaybackProgressEvidence {
  bool _armed = false;
  Duration? _expectedPosition;
  Duration? _baseline;
  int _continuousAdvances = 0;

  bool get isArmed => _armed;

  void arm(Duration expectedPosition) {
    _armed = true;
    _expectedPosition = expectedPosition;
    _baseline = null;
    _continuousAdvances = 0;
  }

  void expect(Duration position) {
    if (!_armed) return;
    _expectedPosition = position;
    _baseline = null;
    _continuousAdvances = 0;
  }

  bool observe(Duration position) {
    if (!_armed) return false;
    final expected = _expectedPosition;
    if (expected != null) {
      final delta = (position - expected).abs();
      if (delta <= const Duration(seconds: 3)) {
        _baseline = position;
        _expectedPosition = null;
        _continuousAdvances = 0;
      }
      return false;
    }

    final baseline = _baseline;
    if (baseline == null) {
      _baseline = position;
      return false;
    }
    final advance = position - baseline;
    if (advance >= const Duration(milliseconds: 100) &&
        advance <= const Duration(seconds: 2)) {
      _baseline = position;
      _continuousAdvances++;
      if (_continuousAdvances >= 2) {
        disarm();
        return true;
      }
      return false;
    }
    if (position < baseline || advance > const Duration(seconds: 2)) {
      _baseline = position;
      _continuousAdvances = 0;
    }
    return false;
  }

  void disarm() {
    _armed = false;
    _expectedPosition = null;
    _baseline = null;
    _continuousAdvances = 0;
  }
}

/// 播放控制栏使用的局部状态。高频变化只刷新进度区域，不重建整个播放页。
@immutable
class PlaybackProgressState {
  final Duration position;
  final Duration duration;
  final Duration buffered;

  const PlaybackProgressState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
  });

  bool get hasKnownDuration => duration > Duration.zero;

  double get progressRatio => hasKnownDuration
      ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : 0.0;

  double get bufferedRatio => hasKnownDuration
      ? (buffered.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
      : 0.0;

  Duration get bufferAhead {
    final difference = buffered - position;
    return difference.isNegative ? Duration.zero : difference;
  }

  PlaybackBufferHealth get bufferHealth {
    if (!hasKnownDuration) return PlaybackBufferHealth.unknown;
    final remaining = duration - position;
    if (!remaining.isNegative &&
        bufferAhead + const Duration(milliseconds: 500) >= remaining) {
      return PlaybackBufferHealth.healthy;
    }
    final seconds = bufferAhead.inMilliseconds / 1000;
    if (seconds < 5) return PlaybackBufferHealth.critical;
    if (seconds < 15) return PlaybackBufferHealth.low;
    return PlaybackBufferHealth.healthy;
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackProgressState &&
      other.position == position &&
      other.duration == duration &&
      other.buffered == buffered;

  @override
  int get hashCode => Object.hash(position, duration, buffered);
}

/// libmpv 的动态预读策略，兼顾倍速、高码率和 64 MiB 内存上限。
@immutable
class PlaybackBufferTuning {
  static const int memoryLimitBytes = 64 * 1024 * 1024;

  final int readaheadSeconds;
  final int cacheSeconds;

  const PlaybackBufferTuning({
    required this.readaheadSeconds,
    required this.cacheSeconds,
  });

  factory PlaybackBufferTuning.forPlayback({
    double playbackRate = 1.0,
    int? bitrate,
  }) {
    var desired = 20;
    if (playbackRate >= 1.5) desired += 10;
    if ((bitrate ?? 0) >= 8 * 1000 * 1000) desired += 10;

    if (bitrate != null && bitrate > 0) {
      // 只让预读最多占用约 80% 缓冲上限，给回退缓存和封装开销留空间。
      final memoryLimited = (memoryLimitBytes * 0.8 / (bitrate / 8))
          .floor()
          .clamp(12, 45);
      desired = desired.clamp(12, memoryLimited).toInt();
    } else {
      desired = desired.clamp(12, 45).toInt();
    }

    return PlaybackBufferTuning(
      readaheadSeconds: desired,
      cacheSeconds: (desired + 10).clamp(22, 60).toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackBufferTuning &&
      other.readaheadSeconds == readaheadSeconds &&
      other.cacheSeconds == cacheSeconds;

  @override
  int get hashCode => Object.hash(readaheadSeconds, cacheSeconds);
}

@immutable
class PlaybackBufferMetricsSnapshot {
  final Duration? firstFrameLatency;
  final int rebufferCount;
  final Duration totalRebufferDuration;
  final Duration? minimumBufferAhead;

  const PlaybackBufferMetricsSnapshot({
    required this.firstFrameLatency,
    required this.rebufferCount,
    required this.totalRebufferDuration,
    required this.minimumBufferAhead,
  });

  @override
  String toString() =>
      'firstFrame=${firstFrameLatency?.inMilliseconds ?? -1}ms, '
      'rebufferCount=$rebufferCount, '
      'rebuffer=${totalRebufferDuration.inMilliseconds}ms, '
      'minAhead=${minimumBufferAhead?.inMilliseconds ?? -1}ms';
}

/// 单集播放期间的轻量指标，用于验证缓存策略，而不是盲目增大缓存。
class PlaybackBufferMetrics {
  DateTime? _openedAt;
  DateTime? _firstFrameAt;
  DateTime? _rebufferStartedAt;
  int _rebufferCount = 0;
  Duration _totalRebufferDuration = Duration.zero;
  Duration? _minimumBufferAhead;

  bool get hasSession => _openedAt != null;

  void reset(DateTime now) {
    _openedAt = now;
    _firstFrameAt = null;
    _rebufferStartedAt = null;
    _rebufferCount = 0;
    _totalRebufferDuration = Duration.zero;
    _minimumBufferAhead = null;
  }

  void markFirstFrame(DateTime now) {
    _firstFrameAt ??= now;
  }

  void onBufferingChanged(bool buffering, DateTime now) {
    if (_firstFrameAt == null) return;
    if (buffering) {
      if (_rebufferStartedAt == null) {
        _rebufferStartedAt = now;
        _rebufferCount++;
      }
      return;
    }
    _finishRebuffer(now);
  }

  void observeBufferAhead(Duration bufferAhead) {
    if (_firstFrameAt == null) return;
    final current = _minimumBufferAhead;
    if (current == null || bufferAhead < current) {
      _minimumBufferAhead = bufferAhead;
    }
  }

  PlaybackBufferMetricsSnapshot snapshot(DateTime now) {
    _finishRebuffer(now);
    final openedAt = _openedAt;
    final firstFrameAt = _firstFrameAt;
    return PlaybackBufferMetricsSnapshot(
      firstFrameLatency: openedAt == null || firstFrameAt == null
          ? null
          : firstFrameAt.difference(openedAt),
      rebufferCount: _rebufferCount,
      totalRebufferDuration: _totalRebufferDuration,
      minimumBufferAhead: _minimumBufferAhead,
    );
  }

  void _finishRebuffer(DateTime now) {
    final startedAt = _rebufferStartedAt;
    if (startedAt == null) return;
    _totalRebufferDuration += now.difference(startedAt);
    _rebufferStartedAt = null;
  }
}
