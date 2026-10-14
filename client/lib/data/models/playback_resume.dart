import 'episode.dart';

typedef EpisodeLocation = ({int groupIndex, int episodeIndex});

class PlaybackResume {
  final String episodeName;
  final int groupIndex;
  final int episodeIndex;
  final int positionMs;

  const PlaybackResume({
    required this.episodeName,
    required this.groupIndex,
    required this.episodeIndex,
    required this.positionMs,
  });

  PlaybackResume at(EpisodeLocation location, String name) => PlaybackResume(
    episodeName: name,
    groupIndex: location.groupIndex,
    episodeIndex: location.episodeIndex,
    positionMs: positionMs,
  );
}

String _normalizedName(String name) => String.fromCharCodes(
  name.runes.map(
    (rune) => rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
  ),
).toLowerCase().replaceAll(RegExp(r'\s+'), '');

int? _chineseNumber(String value) {
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000};
  final chars = value.split('');
  if (chars.every(digits.containsKey)) {
    return int.tryParse(chars.map((c) => digits[c]).join());
  }
  var result = 0, digit = 0;
  for (final char in chars) {
    if (digits.containsKey(char)) {
      digit = digits[char]!;
    } else if (units.containsKey(char)) {
      result += (digit == 0 ? 1 : digit) * units[char]!;
      digit = 0;
    } else {
      return null;
    }
  }
  return result + digit;
}

String _episodeKey(String name) {
  final normalized = _normalizedName(name);
  final numeric =
      RegExp(r'^(?:第)?(\d+)(?:集|话|期)?$').firstMatch(normalized) ??
      RegExp(r'^(?:ep(?:isode)?)[._-]?(\d+)$').firstMatch(normalized);
  if (numeric != null) {
    final number = int.tryParse(numeric.group(1)!);
    if (number != null) return 'episode:$number';
  }
  final chinese = RegExp(
    r'^第([零〇一二两三四五六七八九十百千]+)(?:集|话|期)$',
  ).firstMatch(normalized);
  if (chinese != null) {
    final number = _chineseNumber(chinese.group(1)!);
    if (number != null) return 'episode:$number';
  }
  // Specials, trailers, seasons and split episodes retain their full names.
  return 'name:$normalized';
}

/// Match labels rather than ordinal positions; ambiguous/missing labels fail.
int? matchingEpisodeIndex(
  List<Episode> episodes,
  String name, {
  bool Function(Episode)? playable,
}) {
  if (name.trim().isEmpty) return null;
  final eligible = List.generate(episodes.length, (i) => i).where(
    (i) => playable?.call(episodes[i]) ?? episodes[i].url.trim().isNotEmpty,
  );
  final exact = eligible
      .where((i) => _normalizedName(episodes[i].name) == _normalizedName(name))
      .toList();
  if (exact.isNotEmpty) return exact.length == 1 ? exact.single : null;
  final matches = eligible
      .where((i) => _episodeKey(episodes[i].name) == _episodeKey(name))
      .toList();
  return matches.length == 1 ? matches.single : null;
}

EpisodeLocation? matchingEpisodeLocation(
  List<List<Episode>> groups,
  String name, {
  int preferredGroupIndex = 0,
  bool Function(Episode)? playable,
}) {
  final order = [
    if (preferredGroupIndex >= 0 && preferredGroupIndex < groups.length)
      preferredGroupIndex,
    for (var i = 0; i < groups.length; i++)
      if (i != preferredGroupIndex) i,
  ];
  for (final group in order) {
    final episode = matchingEpisodeIndex(
      groups[group],
      name,
      playable: playable,
    );
    if (episode != null) return (groupIndex: group, episodeIndex: episode);
  }
  return null;
}
