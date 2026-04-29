/// 收藏项，用于收藏列表展示和详情页收藏状态判断
class FavoriteItem {
  final String videoId;
  final String siteKey;
  final String title;
  final String cover;
  final String? year;
  final String? category;
  final String? remarks;
  final DateTime createdAt;

  const FavoriteItem({
    required this.videoId,
    required this.siteKey,
    required this.title,
    required this.cover,
    this.year,
    this.category,
    this.remarks,
    required this.createdAt,
  });

  /// Hive 存储 key
  String get storageKey => '${videoId}_$siteKey';

  Map<String, dynamic> toMap() => {
        'videoId': videoId,
        'siteKey': siteKey,
        'title': title,
        'cover': cover,
        'year': year,
        'category': category,
        'remarks': remarks,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory FavoriteItem.fromMap(Map<String, dynamic> map) => FavoriteItem(
        videoId: map['videoId'] as String,
        siteKey: map['siteKey'] as String,
        title: map['title'] as String,
        cover: map['cover'] as String,
        year: map['year'] as String?,
        category: map['category'] as String?,
        remarks: map['remarks'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      );
}
