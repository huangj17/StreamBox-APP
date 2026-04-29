import 'favorite_item.dart';
import 'watch_history.dart';

/// 影片列表项，用于首页 Rail 和搜索结果展示
class VideoItem {
  final String id;
  final String title;
  final String cover;
  final String? backdrop;
  final String? year;
  final String? category;
  final String? remarks;
  final String? description; // 简介，来自 vod_blurb
  final String? score; // 评分，来自 vod_score
  final String siteKey;

  // 仅在「继续观看」行中有值，用于续播定位
  final int? historyGroupIndex;
  final int? historyEpisodeIndex;
  final int? historyPositionMs;

  const VideoItem({
    required this.id,
    required this.title,
    required this.cover,
    this.backdrop,
    this.year,
    this.category,
    this.remarks,
    this.description,
    this.score,
    required this.siteKey,
    this.historyGroupIndex,
    this.historyEpisodeIndex,
    this.historyPositionMs,
  });

  factory VideoItem.fromJson(Map<String, dynamic> json, {required String siteKey}) =>
      VideoItem(
        id: json['vod_id'].toString(),
        title: json['vod_name'] as String? ?? '',
        cover: fixCoverUrl(json['vod_pic'] as String? ?? ''),
        backdrop: json['vod_blurb_img'] as String?,
        year: json['vod_year'] as String?,
        category: json['vod_class'] as String?,
        remarks: json['vod_remarks'] as String?,
        description: json['vod_blurb'] as String?,
        score: json['vod_score']?.toString(),
        siteKey: siteKey,
      );

  /// 从收藏项创建（用于收藏列表）
  factory VideoItem.fromFavorite(FavoriteItem f) => VideoItem(
        id: f.videoId,
        siteKey: f.siteKey,
        title: f.title,
        cover: f.cover,
        year: f.year,
        category: f.category,
        remarks: f.remarks,
      );

  /// 从观看历史创建（用于「继续观看」行），保留集数和进度用于续播
  factory VideoItem.fromHistory(WatchHistory h) => VideoItem(
        id: h.videoId,
        siteKey: h.siteKey,
        title: h.title,
        cover: h.cover,
        historyGroupIndex: h.groupIndex,
        historyEpisodeIndex: h.episodeIndex,
        historyPositionMs: h.positionMs,
      );

  /// 修复 Spider 返回的图片 URL：
  /// - Bridge proxy URL 已由服务端修正 host，无需客户端处理
  /// - 拼接错误：https://domain1https://domain2/path → 取后半段
  static String fixCoverUrl(String url) {
    if (url.isEmpty) return url;

    // 处理拼接错误的 URL（中间出现 http），但跳过 proxy URL
    if (!url.contains('/proxy?')) {
      final idx = url.indexOf('http', 1);
      if (idx > 0) return url.substring(idx);
    }

    return url;
  }
}
