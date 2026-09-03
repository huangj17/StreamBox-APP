/// Application-owned catalog endpoint; HTTP is allowed only for this URL.
class OfficialSources {
  static const url = String.fromEnvironment(
    'STREAMBOX_SOURCES_URL',
    defaultValue: 'http://1.14.171.39/streambox/sources.json',
  );
  static const refreshInterval = Duration(minutes: 30);

  // Historical identity mapping only, never a source list to load as fallback.
  // Keep these IDs stable when replacing an API URL in the remote document.
  static const legacyApis = {
    'baofeng': 'https://bfzyapi.com/api.php/provide/vod/',
    'hongniu': 'https://www.hongniuzy2.com/api.php/provide/vod/',
  };
}
