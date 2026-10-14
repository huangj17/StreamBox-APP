import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/site.dart';
import '../../../data/models/source_health.dart';

class SourcePlaybackSample {
  final bool succeeded;
  final int? startupMs;
  const SourcePlaybackSample(this.succeeded, this.startupMs);
}

/// Bounded observations from actual playback in the current app session.
class SourcePlaybackNotifier
    extends StateNotifier<Map<String, List<SourcePlaybackSample>>> {
  SourcePlaybackNotifier() : super(const {});

  void record(Site site, {required bool succeeded, int? startupMs}) {
    final samples = [
      ...?state[site.identity],
      SourcePlaybackSample(succeeded, startupMs),
    ];
    state = {
      ...state,
      site.identity: List.unmodifiable(
        samples.skip((samples.length - 8).clamp(0, 8)),
      ),
    };
  }
}

final sourcePlaybackProvider =
    StateNotifierProvider<
      SourcePlaybackNotifier,
      Map<String, List<SourcePlaybackSample>>
    >((ref) => SourcePlaybackNotifier());

double sourceRecommendationScore(
  Site site,
  Map<String, SourceHealth> health,
  Map<String, List<SourcePlaybackSample>> playback,
) {
  var score = switch (health[site.api]?.status) {
    SourceHealthStatus.available => 20.0,
    SourceHealthStatus.unavailable => -10.0,
    _ => 0.0,
  };
  final samples = playback[site.identity] ?? const [];
  if (samples.isNotEmpty) {
    // A small prior keeps a single observation from dominating every source.
    final successes = samples.where((s) => s.succeeded).length;
    score += ((successes + 1) / (samples.length + 2) - 0.5) * 60;
    final starts = samples
        .where((s) => s.succeeded && s.startupMs != null)
        .toList();
    if (starts.isNotEmpty) {
      final average =
          starts.fold<int>(0, (sum, s) => sum + s.startupMs!) / starts.length;
      score += (5 - average / 1000).clamp(0, 5);
    }
  }
  return score;
}
