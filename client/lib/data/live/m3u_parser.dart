import '../../core/network/url_policy.dart';
import '../models/live_channel.dart';

/// Parses channel playlists, not HLS media/master manifests. Missing or unsafe
/// URLs are skipped without assigning the next channel's URL to the wrong name.
List<LiveChannel> parseLiveM3u(String text, {required Uri base}) {
  text = text.replaceFirst(RegExp(r'^\ufeff'), '');
  if (!text.trimLeft().startsWith('#EXTM3U') ||
      RegExp(r'^#EXT-X-', multiLine: true).hasMatch(text)) {
    throw const FormatException('请填写 M3U 频道列表地址，而不是视频流或网页地址');
  }
  final result = <LiveChannel>[];
  final seen = <String>{};
  Map<String, String>? attributes;
  String? name;
  var headers = <String, String>{};
  final attributePattern = RegExp(
    r'''([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))''',
  );
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF:')) {
      String? quote;
      var comma = -1;
      for (var i = 0; i < line.length; i++) {
        final c = line[i];
        if (quote == null && (c == '"' || c == "'")) {
          quote = c;
        } else if (quote == c) {
          quote = null;
        } else if (quote == null && c == ',') {
          comma = i;
          break;
        }
      }
      attributes = {
        for (final m in attributePattern.allMatches(
          comma < 0 ? line : line.substring(0, comma),
        ))
          m[1]!.toLowerCase(): m[2] ?? m[3] ?? m[4] ?? '',
      };
      name = comma < 0 ? null : line.substring(comma + 1).trim();
      headers = {};
      continue;
    }
    if (line.startsWith('#EXTVLCOPT:') && attributes != null) {
      final option = line.substring(11);
      final equals = option.indexOf('=');
      if (equals > 0) {
        final key = switch (option.substring(0, equals).toLowerCase()) {
          'http-user-agent' => 'User-Agent',
          'http-referrer' => 'Referer',
          _ => null,
        };
        final value = option.substring(equals + 1).trim();
        if (key != null && !value.contains(RegExp(r'[\r\n]'))) {
          headers[key] = value;
        }
      }
      continue;
    }
    if (line.isEmpty || line.startsWith('#') || attributes == null) continue;
    final metadata = attributes;
    attributes = null;
    if (name == null || name.isEmpty) continue;
    try {
      final url = UrlPolicy.requirePlaybackUrl(base.resolve(line).toString());
      String? logo;
      final rawLogo = metadata['tvg-logo'];
      if (rawLogo != null && rawLogo.isNotEmpty) {
        try {
          logo = UrlPolicy.requirePlaybackUrl(
            base.resolve(rawLogo).toString(),
          ).toString();
        } on FormatException {
          /* An invalid logo must not hide the channel. */
        }
      }
      final channel = LiveChannel(
        name: name,
        group: metadata['group-title']?.trim().isNotEmpty == true
            ? metadata['group-title']!.trim()
            : '未分组',
        url: url.toString(),
        logo: logo,
        tvgId: metadata['tvg-id'] ?? metadata['tvg-name'],
        headers: Map.unmodifiable(headers),
      );
      if (seen.add(channel.identity)) result.add(channel);
    } on FormatException {
      // Invalid entries are isolated from the rest of the subscription.
    }
    if (result.length > 10000) {
      throw const FormatException('频道数量超过上限（10000）');
    }
  }
  if (result.isEmpty) throw const FormatException('订阅中没有可播放的 HTTP(S) 频道');
  return List.unmodifiable(result);
}
