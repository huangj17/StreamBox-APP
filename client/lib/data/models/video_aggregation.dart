import 'video_item.dart';

String videoSourceIdentity(VideoItem item) => '${item.siteKey}:${item.id}';

/// Remove presentation differences, preserving season, cut and language names.
String normalizedVideoTitle(String title) => title
    .toLowerCase()
    .replaceAll(
      RegExp(
        r'[（(\[]\s*(?:4k|1080p|720p|2160p|高清|超清)\s*[）)\]]',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

String? _year(String? value) {
  final year = value?.trim();
  return year != null && RegExp(r'^(19|20)\d{2}$').hasMatch(year) ? year : null;
}

String? _doubanId(String? value) {
  final id = value?.trim();
  return id != null && RegExp(r'^[1-9]\d*$').hasMatch(id) ? id : null;
}

String? _kind(VideoItem item) {
  final type = '${item.mediaType ?? ''} ${item.category ?? ''}';
  if (RegExp(r'短剧').hasMatch(type)) return 'short';
  if (RegExp(r'动漫|动画|卡通').hasMatch(type)) return 'animation';
  if (RegExp(r'综艺').hasMatch(type)) return 'variety';
  if (RegExp(r'电视剧|连续剧|国产剧|港剧|香港剧|韩剧|日剧|美剧|欧美剧|台剧|海外剧').hasMatch(type)) {
    return 'series';
  }
  if (RegExp(r'电影|片').hasMatch(type)) return 'movie';
  return null;
}

/// Conflicting metadata must never be bridged by a result with missing fields.
bool videoMetadataCompatible(VideoItem a, VideoItem b) {
  final title = normalizedVideoTitle(a.title);
  if (title.isEmpty || title != normalizedVideoTitle(b.title)) return false;
  final ay = _year(a.year), by = _year(b.year);
  if (ay != null && by != null && ay != by) return false;
  final ak = _kind(a), bk = _kind(b);
  if (ak != null && bk != null && ak != bk) return false;
  final ad = _doubanId(a.doubanId), bd = _doubanId(b.doubanId);
  return ad == null || bd == null || ad == bd;
}

bool sameVideoWork(VideoItem a, VideoItem b) {
  if (videoSourceIdentity(a) == videoSourceIdentity(b)) return true;
  if (!videoMetadataCompatible(a, b)) return false;
  final ad = _doubanId(a.doubanId), bd = _doubanId(b.doubanId);
  if (ad != null && ad == bd) return true;
  final ay = _year(a.year), by = _year(b.year);
  // Title alone is insufficient for unknown years and remakes.
  return ay != null && ay == by;
}

/// Keep first-arrival group order/keys while replacing only its representative.
List<VideoItem> aggregateVideos(
  List<VideoItem> items, {
  int Function(VideoItem, VideoItem)? compareSources,
}) {
  final seen = <String>{};
  final groups = <List<VideoItem>>[];
  for (final item in items) {
    if (!seen.add(videoSourceIdentity(item))) continue;
    final matches = groups
        .where(
          (group) =>
              group.any((v) => sameVideoWork(v, item)) &&
              group.every((v) => videoMetadataCompatible(v, item)),
        )
        .toList();
    if (matches.length == 1) {
      matches.single.add(item);
    } else {
      groups.add([item]);
    }
  }
  return List.unmodifiable(
    groups.map((group) {
      final ordered = List<VideoItem>.of(group);
      if (compareSources != null) ordered.sort(compareSources);
      return ordered.first.withSources(
        videoSourceIdentity(group.first),
        ordered,
      );
    }),
  );
}
