/// Only this application-owned endpoint may use public HTTP for configuration.
/// Prefer an HTTPS URL when a domain/certificate is available.
class OfficialSources {
  static const url = String.fromEnvironment(
    'STREAMBOX_SOURCES_URL',
    defaultValue: 'http://1.14.171.39/streambox/sources.json',
  );
  static const refreshInterval = Duration(minutes: 30);

  // Keep these IDs stable when replacing an API URL in the remote document.
  static const bundledApis = {
    'baofeng': 'https://bfzyapi.com/api.php/provide/vod/',
    'hongniu': 'https://www.hongniuzy2.com/api.php/provide/vod/',
  };
}
