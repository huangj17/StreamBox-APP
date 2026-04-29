/// 观看历史记录，用于「继续观看」行和播放续播
class WatchHistory {
  final String videoId;
  final String siteKey;
  final String title;
  final String cover;
  final String episodeName;
  final int episodeIndex;
  final int groupIndex; // 线路索引，用于续播时恢复到正确的播放源
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;
  final String? category; // 分类名（如"动作片"），用于首页分类排序

  const WatchHistory({
    required this.videoId,
    required this.siteKey,
    required this.title,
    required this.cover,
    required this.episodeName,
    required this.episodeIndex,
    this.groupIndex = 0,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.category,
  });

  /// 进度百分比，用于渲染进度条
  double get progress => durationMs > 0 ? positionMs / durationMs : 0.0;

  /// Hive 存储 key
  String get storageKey => '${videoId}_$siteKey';

  Map<String, dynamic> toMap() => {
        'videoId': videoId,
        'siteKey': siteKey,
        'title': title,
        'cover': cover,
        'episodeName': episodeName,
        'episodeIndex': episodeIndex,
        'groupIndex': groupIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
        if (category != null) 'category': category,
      };

  factory WatchHistory.fromMap(Map<String, dynamic> map) => WatchHistory(
        videoId: map['videoId'] as String,
        siteKey: map['siteKey'] as String,
        title: map['title'] as String,
        cover: map['cover'] as String,
        episodeName: map['episodeName'] as String,
        episodeIndex: map['episodeIndex'] as int,
        groupIndex: map['groupIndex'] as int? ?? 0,
        positionMs: map['positionMs'] as int,
        durationMs: map['durationMs'] as int,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
        category: map['category'] as String?,
      );
}
