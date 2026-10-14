import '../../data/models/live_channel.dart';

/// Restore a channel rather than its old position or an expiring stream URL.
/// Use the exact last working line when present, otherwise use a current line
/// for that station. Ambiguous matches never jump to an unrelated group.
int liveResumeIndex(List<LiveChannel> channels, LiveChannel? last) {
  if (last == null || channels.isEmpty) return 0;
  final exact = channels.indexWhere((c) => c.identity == last.identity);
  if (exact >= 0) return exact;
  String normal(String value) => value.trim().toLowerCase();
  bool sameName(LiveChannel c) => normal(c.name) == normal(last.name);
  bool sameGroup(LiveChannel c) => normal(c.group) == normal(last.group);
  bool sameId(LiveChannel c) =>
      last.tvgId?.trim().isNotEmpty == true &&
      normal(c.tvgId ?? '') == normal(last.tvgId!);
  int match(bool Function(LiveChannel) matches, {bool unique = false}) {
    final candidates = [
      for (var i = 0; i < channels.length; i++)
        if (matches(channels[i])) i,
    ];
    if (candidates.isEmpty) return -1;
    if (unique &&
        candidates
                .map(
                  (i) =>
                      '${normal(channels[i].group)}\u0000${normal(channels[i].name)}',
                )
                .toSet()
                .length !=
            1) {
      return -1;
    }
    return candidates.firstWhere(
      (i) => channels[i].url == last.url,
      orElse: () => candidates.first,
    );
  }

  for (final index in [
    match((c) => sameName(c) && sameGroup(c)),
    match((c) => sameId(c) && sameGroup(c), unique: true),
    match(sameName, unique: true),
    match(sameId, unique: true),
  ]) {
    if (index >= 0) return index;
  }
  return 0;
}

/// Some subscriptions include an update timestamp as a fake channel pointing
/// at CCTV-1. Exclude only these recognisable metadata rows, including caches.
List<LiveChannel> liveViewingChannels(List<LiveChannel> channels) => channels
    .where(
      (c) => !RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}').hasMatch(c.name),
    )
    .toList(growable: false);

class LiveStation {
  final List<int> lines;
  LiveStation(int first) : lines = [first];
}

/// Alternate addresses for the same channel within a group are lines, rather
/// than repeated stations. Keep every original URL and header for line choice.
class LiveCatalog {
  final List<LiveChannel> channels;
  final stations = <LiveStation>[];
  final _stationForLine = <int, int>{};
  LiveCatalog(this.channels) {
    final byName = <String, int>{};
    for (var i = 0; i < channels.length; i++) {
      final c = channels[i];
      final key = '${c.group}\u0000${c.name.trim().toLowerCase()}';
      final station = byName[key];
      if (station == null) {
        byName[key] = stations.length;
        _stationForLine[i] = stations.length;
        stations.add(LiveStation(i));
      } else {
        _stationForLine[i] = station;
        stations[station].lines.add(i);
      }
    }
  }
  int stationForLine(int line) => _stationForLine[line]!;
  List<String> get groups => channels.map((c) => c.group).toSet().toList();
  List<int> stationIndices(String? group) => [
    for (var i = 0; i < stations.length; i++)
      if (group == null || channels[stations[i].lines.first].group == group) i,
  ];
}
