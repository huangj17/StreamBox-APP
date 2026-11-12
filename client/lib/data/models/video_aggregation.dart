import 'video_item.dart';

String videoSourceIdentity(VideoItem item) => '${item.siteKey}:${item.id}';

final _qualityTag = RegExp(
  r'[（(\[]\s*(?:4k|1080p|720p|2160p|高清|超清)\s*[）)\]]',
  caseSensitive: false,
);
final _titleSeparators = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
final _yearPattern = RegExp(r'^(19|20)\d{2}$');
final _doubanIdPattern = RegExp(r'^[1-9]\d*$');
final _shortKind = RegExp(r'短剧');
final _animationKind = RegExp(r'动漫|动画|卡通');
final _varietyKind = RegExp(r'综艺');
final _seriesKind = RegExp(r'电视剧|连续剧|国产剧|港剧|香港剧|韩剧|日剧|美剧|欧美剧|台剧|海外剧');
final _movieKind = RegExp(r'电影|片');

/// Remove presentation differences, preserving season, cut and language names.
String normalizedVideoTitle(String title) => title
    .toLowerCase()
    .replaceAll(_qualityTag, '')
    .replaceAll(_titleSeparators, '');

String? _year(String? value) {
  final year = value?.trim();
  return year != null && _yearPattern.hasMatch(year) ? year : null;
}

String? _doubanId(String? value) {
  final id = value?.trim();
  return id != null && _doubanIdPattern.hasMatch(id) ? id : null;
}

String? _kind(VideoItem item) {
  final type = '${item.mediaType ?? ''} ${item.category ?? ''}';
  if (_shortKind.hasMatch(type)) return 'short';
  if (_animationKind.hasMatch(type)) return 'animation';
  if (_varietyKind.hasMatch(type)) return 'variety';
  if (_seriesKind.hasMatch(type)) return 'series';
  if (_movieKind.hasMatch(type)) return 'movie';
  return null;
}

/// Matching metadata, normalized once per item so grouping stays cheap.
class _VideoFacts {
  final String title;
  final String? year;
  final String? kind;
  final String? doubanId;

  _VideoFacts(VideoItem item)
    : title = normalizedVideoTitle(item.title),
      year = _year(item.year),
      kind = _kind(item),
      doubanId = _doubanId(item.doubanId);

  /// Conflicting metadata must never be bridged by a result with missing fields.
  bool compatibleWith(_VideoFacts other) {
    if (title.isEmpty || title != other.title) return false;
    if (year != null && other.year != null && year != other.year) return false;
    if (kind != null && other.kind != null && kind != other.kind) return false;
    return doubanId == null ||
        other.doubanId == null ||
        doubanId == other.doubanId;
  }

  bool sameWorkAs(_VideoFacts other) {
    if (!compatibleWith(other)) return false;
    if (doubanId != null && doubanId == other.doubanId) return true;
    // Title alone is insufficient for unknown years and remakes.
    return year != null && year == other.year;
  }
}

bool videoMetadataCompatible(VideoItem a, VideoItem b) =>
    _VideoFacts(a).compatibleWith(_VideoFacts(b));

bool sameVideoWork(VideoItem a, VideoItem b) =>
    videoSourceIdentity(a) == videoSourceIdentity(b) ||
    _VideoFacts(a).sameWorkAs(_VideoFacts(b));

typedef _Member = ({VideoItem item, _VideoFacts facts});

/// Incremental cross-source grouping.
///
/// Feeding items in batches yields exactly the same groups as aggregating the
/// concatenated list at once, so results can be merged as each source returns.
class VideoAggregator {
  final int Function(VideoItem, VideoItem)? compareSources;
  final _seen = <String>{};
  final _groups = <List<_Member>>[];

  /// Only groups sharing a normalized title can ever be compatible.
  final _groupsByTitle = <String, List<List<_Member>>>{};

  VideoAggregator({this.compareSources});

  bool get isEmpty => _groups.isEmpty;

  void addAll(Iterable<VideoItem> items) {
    for (final item in items) {
      if (!_seen.add(videoSourceIdentity(item))) continue;
      final facts = _VideoFacts(item);
      final member = (item: item, facts: facts);
      final candidates = facts.title.isEmpty
          ? const <List<_Member>>[]
          : _groupsByTitle[facts.title] ?? const <List<_Member>>[];
      final matches = candidates
          .where(
            (group) =>
                group.any((m) => m.facts.sameWorkAs(facts)) &&
                group.every((m) => m.facts.compatibleWith(facts)),
          )
          .take(2)
          .toList();
      if (matches.length == 1) {
        matches.single.add(member);
      } else {
        final group = [member];
        _groups.add(group);
        if (facts.title.isNotEmpty) {
          (_groupsByTitle[facts.title] ??= []).add(group);
        }
      }
    }
  }

  /// Keep first-arrival group order/keys while replacing only its representative.
  List<VideoItem> snapshot() => List.unmodifiable(
    _groups.map((group) {
      final ordered = [for (final m in group) m.item];
      if (compareSources != null) ordered.sort(compareSources);
      return ordered.first.withSources(
        videoSourceIdentity(group.first.item),
        ordered,
      );
    }),
  );
}

List<VideoItem> aggregateVideos(
  List<VideoItem> items, {
  int Function(VideoItem, VideoItem)? compareSources,
}) =>
    (VideoAggregator(compareSources: compareSources)..addAll(items)).snapshot();
