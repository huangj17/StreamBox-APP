import '../../../data/models/episode.dart';

/// 播放器剧集状态（数据模型，状态由 PlayerScreen 本地管理）
class PlayerEpisodeState {
  final List<List<Episode>> episodeGroups;
  final List<String> sourceNames;
  final int groupIndex;
  final int episodeIndex;

  const PlayerEpisodeState({
    required this.episodeGroups,
    required this.sourceNames,
    this.groupIndex = 0,
    this.episodeIndex = 0,
  });

  Episode get current => episodeGroups[groupIndex][episodeIndex];
  List<Episode> get currentGroup => episodeGroups[groupIndex];
  bool get hasPrev => episodeIndex > 0;
  bool get hasNext => episodeIndex < currentGroup.length - 1;
  String get sourceName => sourceNames.length > groupIndex
      ? sourceNames[groupIndex]
      : '线路 ${groupIndex + 1}';

  PlayerEpisodeState copyWith({int? groupIndex, int? episodeIndex}) =>
      PlayerEpisodeState(
        episodeGroups: episodeGroups,
        sourceNames: sourceNames,
        groupIndex: groupIndex ?? this.groupIndex,
        episodeIndex: episodeIndex ?? this.episodeIndex,
      );
}
