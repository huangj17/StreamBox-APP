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
  }) => VideoListResult(
    items: (json['list'] is List ? json['list'] as List : const [])
        .whereType<Map>()
        .map(
          (e) => VideoItem.fromJson(
            Map<String, dynamic>.from(e),
            siteKey: siteKey,
          ),
        )
        .toList(),
    total: _intValue(json['total'], fallback: 0),
    pageCount: _intValue(json['pagecount'], fallback: 1),
  );
}

int _intValue(Object? value, {required int fallback}) => switch (value) {
  final num number => number.toInt(),
  final String text => int.tryParse(text) ?? fallback,
  _ => fallback,
};
