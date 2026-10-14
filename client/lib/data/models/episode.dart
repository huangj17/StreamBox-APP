import '../../core/network/url_policy.dart';
import 'site.dart';

class Episode {
  final String name;
  final String url;
  final String sourceFlag;
  final bool requiresResolve;
  final Map<String, String>? headers;

  const Episode({
    required this.name,
    required this.url,
    this.sourceFlag = '',
    this.requiresResolve = false,
    this.headers,
  });
}

bool canPlayEpisode(Site site, Episode episode) {
  if (episode.url.trim().isEmpty) return false;
  if (site.isJar) return true;
  if (episode.requiresResolve) return false;
  try {
    UrlPolicy.requirePlaybackUrl(episode.url);
    return true;
  } on FormatException {
    return false;
  }
}
