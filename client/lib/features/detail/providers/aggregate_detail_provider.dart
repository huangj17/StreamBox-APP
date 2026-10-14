import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/source_error_message.dart';
import '../../../data/models/cms_video_detail.dart';
import '../../../data/models/episode.dart';
import '../../../data/models/site.dart';
import '../../../data/models/video_item.dart';
import '../../../data/models/video_aggregation.dart';
import '../../../data/sources/cms_api.dart';
import '../../home/providers/categories_provider.dart';
import '../../source/providers/source_provider.dart';
import '../../source/providers/source_library_provider.dart';
import '../../source/providers/source_playback_provider.dart';

class ResolvedVideoSource {
  final VideoItem video;
  final Site site;
  final CmsVideoDetail detail;
  final int responseMs;
  final double sourceScore;
  const ResolvedVideoSource({
    required this.video,
    required this.site,
    required this.detail,
    required this.responseMs,
    required this.sourceScore,
  });

  String get identity => videoSourceIdentity(video);
  int get playableEpisodes => detail.episodeGroups.fold<int>(0, (best, group) {
    final count = group.where((ep) => canPlayEpisode(site, ep)).length;
    return count > best ? count : best;
  });
  int get recommendedGroup {
    final groups = detail.episodeGroups;
    var best = 0, count = 0;
    for (var i = 0; i < groups.length; i++) {
      final next = groups[i].where((ep) => canPlayEpisode(site, ep)).length;
      if (next > count) {
        best = i;
        count = next;
      }
    }
    return best;
  }

  double get score {
    final names = detail.sourceNames.join(' ').toLowerCase();
    // Labels are only hints; availability and actual playback outweigh them.
    final quality = names.contains('4k')
        ? 4
        : names.contains('1080')
        ? 3
        : names.contains('720')
        ? 2
        : 0;
    return sourceScore +
        playableEpisodes.clamp(0, 30) +
        quality +
        (3 - responseMs / 1000).clamp(0, 3);
  }
}

class AggregateDetailState {
  final List<VideoItem> candidates;
  final List<ResolvedVideoSource> resolved;
  final Map<String, String> failures;
  final Set<String> checking;
  final int completed;
  final String? initialSelection;
  const AggregateDetailState({
    required this.candidates,
    this.resolved = const [],
    this.failures = const {},
    this.checking = const {},
    this.completed = 0,
    this.initialSelection,
  });

  bool get loading => completed < candidates.length;
  String? get firstAvailableIdentity {
    for (final candidate in candidates) {
      final id = videoSourceIdentity(candidate);
      if (resolved.any((s) => s.identity == id && s.playableEpisodes > 0)) {
        return id;
      }
    }
    return null;
  }

  List<ResolvedVideoSource> get ranked {
    final result = resolved.where((s) => s.playableEpisodes > 0).toList();
    final order = {
      for (var i = 0; i < candidates.length; i++)
        videoSourceIdentity(candidates[i]): i,
    };
    result.sort((a, b) {
      final rank = b.score.compareTo(a.score);
      return rank != 0
          ? rank
          : order[a.identity]!.compareTo(order[b.identity]!);
    });
    return result;
  }

  AggregateDetailState copyWith({
    List<ResolvedVideoSource>? resolved,
    Map<String, String>? failures,
    Set<String>? checking,
    int? completed,
    String? initialSelection,
  }) => AggregateDetailState(
    candidates: candidates,
    resolved: resolved ?? this.resolved,
    failures: failures ?? this.failures,
    checking: checking ?? this.checking,
    completed: completed ?? this.completed,
    initialSelection: initialSelection ?? this.initialSelection,
  );
}

class AggregateDetailNotifier extends StateNotifier<AggregateDetailState> {
  final CmsApi api;
  final Map<String, Site> sites;
  final double Function(Site) scoreSource;
  final String? preferredSiteIdentity;
  final _tokens = <String, CancelToken>{};
  static const perSourceBudget = Duration(seconds: 6);

  AggregateDetailNotifier({
    required this.api,
    required this.sites,
    required this.scoreSource,
    this.preferredSiteIdentity,
    required List<VideoItem> candidates,
  }) : super(
         AggregateDetailState(
           candidates: List.unmodifiable([
             ...candidates.where(
               (v) =>
                   preferredSiteIdentity != null &&
                   sites[v.siteKey]?.identity == preferredSiteIdentity,
             ),
             ...candidates.where(
               (v) =>
                   preferredSiteIdentity == null ||
                   sites[v.siteKey]?.identity != preferredSiteIdentity,
             ),
           ]),
         ),
       );

  Future<void> load() async {
    if (!mounted) return;
    final attempted = <String>{};
    // The explicit home selection takes precedence over health/quality scores.
    // Show it as soon as it loads, without waiting for unrelated sources.
    if (preferredSiteIdentity != null) {
      final preferred = state.candidates
          .where((v) => sites[v.siteKey]?.identity == preferredSiteIdentity)
          .toList();
      for (final candidate in preferred) {
        await _fetch(candidate);
        if (!mounted) return;
        attempted.add(videoSourceIdentity(candidate));
        state = state.copyWith(completed: attempted.length);
        _selectInitial();
        if (state.initialSelection != null) break;
      }
    }
    final remaining = state.candidates
        .where((v) => !attempted.contains(videoSourceIdentity(v)))
        .toList();
    // Alternatives remain available for manual selection. Background results
    // never replace the source already displayed or move remote-control focus.
    for (var start = 0; start < remaining.length; start += 3) {
      final batch = remaining.skip(start).take(3).toList();
      await Future.wait(batch.map(_fetch));
      if (!mounted) return;
      attempted.addAll(batch.map(videoSourceIdentity));
      state = state.copyWith(completed: attempted.length);
      _selectInitial();
    }
  }

  void _selectInitial() {
    if (state.initialSelection == null &&
        state.firstAvailableIdentity != null) {
      state = state.copyWith(initialSelection: state.firstAvailableIdentity);
    }
  }

  Future<void> retry(VideoItem video) => _fetch(video);

  Future<void> _fetch(VideoItem video) async {
    final id = videoSourceIdentity(video);
    if (!mounted || _tokens.containsKey(id)) return;
    final site = sites[video.siteKey];
    if (site == null) {
      state = state.copyWith(failures: {...state.failures, id: '片源已停用或移除'});
      return;
    }
    final token = CancelToken();
    _tokens[id] = token;
    state = state.copyWith(
      checking: {...state.checking, id},
      failures: {...state.failures}..remove(id),
    );
    final watch = Stopwatch()..start();
    try {
      final detail = await api
          .fetchVideoDetail(site: site, videoId: video.id, cancelToken: token)
          .timeout(
            perSourceBudget,
            onTimeout: () {
              token.cancel('影片详情超时');
              throw TimeoutException('影片详情超时');
            },
          );
      if (!mounted) return;
      if (detail == null) throw const FormatException('该片源未找到影片');
      final actual = VideoItem(
        id: detail.vodId,
        title: detail.vodName,
        cover: detail.vodPic,
        siteKey: site.key,
        year: detail.vodYear,
        category: detail.vodClass,
        mediaType: detail.mediaType,
        doubanId: detail.vodDoubanId,
      );
      if (!videoMetadataCompatible(video, actual)) {
        throw const FormatException('详情与搜索结果不匹配');
      }
      final resolved = ResolvedVideoSource(
        video: video,
        site: site,
        detail: detail,
        responseMs: watch.elapsedMilliseconds,
        sourceScore: scoreSource(site),
      );
      if (resolved.playableEpisodes == 0) {
        throw const FormatException('没有当前播放器支持的线路');
      }
      state = state.copyWith(
        resolved: [...state.resolved.where((s) => s.identity != id), resolved],
      );
      if (!state.loading && state.initialSelection == null) {
        _selectInitial();
      }
    } catch (error) {
      if (mounted) {
        state = state.copyWith(
          failures: {...state.failures, id: sourceErrorMessage(error)},
        );
      }
    } finally {
      _tokens.remove(id);
      if (mounted) {
        state = state.copyWith(checking: {...state.checking}..remove(id));
      }
    }
  }

  @override
  void dispose() {
    for (final token in _tokens.values) {
      token.cancel('已离开影片详情');
    }
    super.dispose();
  }
}

final aggregateDetailProvider = StateNotifierProvider.autoDispose
    .family<AggregateDetailNotifier, AggregateDetailState, VideoItem>((
      ref,
      video,
    ) {
      final sites = {
        for (final site in ref.watch(sitesProvider)) site.key: site,
      };
      final health = ref.read(sourceHealthProvider);
      final playback = ref.read(sourcePlaybackProvider);
      final candidates = video.sources.isEmpty ? [video] : video.sources;
      final configuredHome = ref.read(sourceLibraryProvider).homeIdentity;
      final preferredSite =
          sites.values.where((s) => s.identity == configuredHome).firstOrNull ??
          ref.read(homeSitesProvider).firstOrNull;
      final notifier = AggregateDetailNotifier(
        api: ref.read(cmsApiProvider),
        sites: sites,
        scoreSource: (site) =>
            sourceRecommendationScore(site, health, playback),
        candidates: candidates,
        preferredSiteIdentity: preferredSite?.identity,
      );
      unawaited(Future<void>.microtask(notifier.load));
      return notifier;
    });
