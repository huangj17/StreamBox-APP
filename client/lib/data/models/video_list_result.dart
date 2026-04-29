import 'video_item.dart';

/// 分页视频列表结果
class VideoListResult {
  final List<VideoItem> items;
  final int total;
  final int pageCount;

  const VideoListResult({
    required this.items,
    required this.total,
    required this.pageCount,
  });

  factory VideoListResult.fromJson(
    Map<String, dynamic> json, {
    required String siteKey,
  }) =>
      VideoListResult(
        items: (json['list'] as List<dynamic>? ?? [])
            .map((e) => VideoItem.fromJson(e as Map<String, dynamic>, siteKey: siteKey))
            .toList(),
        total: json['total'] as int? ?? 0,
        pageCount: json['pagecount'] as int? ?? 1,
      );
}
