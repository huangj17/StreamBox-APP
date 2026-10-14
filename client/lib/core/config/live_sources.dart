class LiveSources {
  static const url = String.fromEnvironment(
    'STREAMBOX_LIVE_SOURCES_URL',
    defaultValue: 'http://1.14.171.39/streambox/live_sources.json',
  );
  static const refreshInterval = Duration(minutes: 30);
  // Migration identities only; never a default list or download fallback.
  static const legacyIds = {
    'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv4/result.m3u':
        'guovin-ipv4',
    'https://raw.githubusercontent.com/ngo5/IPTV/main/m3u/ipv4.m3u':
        'ngo5-ipv4',
    'https://raw.githubusercontent.com/ngo5/IPTV/main/m3u/ipv6.m3u':
        'ngo5-ipv6',
  };
}
