import 'package:flutter/foundation.dart';
import '../../core/network/url_policy.dart';

enum SiteSourceKind { cms, jar, unknown }

/// CMS endpoints are portable; csp_ entry points run only in the Android host.
class Site {
  final String key;
  final String name;
  final int type;
  final String api;
  final bool searchable;
  final bool isEnabled;
  final SiteSourceKind sourceKind;
  final String? configUrl;
  final String? jar;
  final Object? ext;
  final Map<String, dynamic> options;
  final bool retiredBridge;

  const Site({
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    this.searchable = true,
    this.isEnabled = true,
    this.sourceKind = SiteSourceKind.unknown,
    this.configUrl,
    this.jar,
    this.ext,
    this.options = const {},
    this.retiredBridge = false,
  });

  factory Site.fromJson(
    Map<String, dynamic> json, {
    String? configUrl,
    String? defaultJar,
  }) {
    final base = configUrl ?? json['configUrl']?.toString();
    final api = resolveReference(json['api']?.toString().trim() ?? '', base);
    final jar = json['jar']?.toString() ?? defaultJar;
    final rawExt = json['ext'];
    return Site(
      key: json['key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: switch (json['type']) {
        final num value => value.toInt(),
        final String value => int.tryParse(value) ?? 3,
        _ => 3,
      },
      api: api,
      searchable: _boolLike(json['searchable'], defaultValue: true),
      isEnabled: _boolLike(json['isEnabled'], defaultValue: true),
      sourceKind: api.startsWith('csp_')
          ? SiteSourceKind.jar
          : _isHttp(api) && !_isScript(api)
          ? SiteSourceKind.cms
          : SiteSourceKind.unknown,
      configUrl: base,
      jar: jar == null ? null : resolveReference(jar, base),
      ext: rawExt is String ? resolveReference(rawExt, base) : rawExt,
      options: Map.unmodifiable(json),
      retiredBridge:
          json['retiredBridge'] == true ||
          json['gatewayUrl'] != null ||
          json['bridgeUrl'] != null ||
          UrlPolicy.isRetiredBridgeUrl(api),
    );
  }

  factory Site.fromUrl(String url, {String? name}) => Site(
    key: url.hashCode.toString(),
    name: name ?? Uri.parse(url).host,
    type: 3,
    api: url,
    sourceKind: SiteSourceKind.cms,
    retiredBridge: UrlPolicy.isRetiredBridgeUrl(url),
  );

  bool get isJar => api.startsWith('csp_');
  bool get isVisible => !retiredBridge && (!isJar || supportsAndroidJar);
  static bool get supportsAndroidJar =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get isSupported =>
      isVisible &&
      (isJar
          ? jar != null && jar!.isNotEmpty && configUrl != null
          : {0, 1, 3}.contains(type) &&
                UrlPolicy.isSafeCmsApi(api) &&
                !_isScript(api));

  /// Keep bundle updates and shared class names from breaking source identity.
  String get identity => isJar
      ? 'jar:${configUrl ?? ''}#${options['upstreamKey'] ?? options['key'] ?? key}'
      : canonicalApi(api);
  Map<String, String> get headers {
    final raw = options['header'];
    return raw is Map
        ? raw.map((k, v) => MapEntry(k.toString(), v.toString()))
        : const {};
  }

  static String canonicalApi(String api) {
    final uri = Uri.tryParse(api.trim());
    return uri == null
        ? api.trim()
        : uri
              .replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
              .toString();
  }

  /// Resolve explicit relative references, leaving tokens and inline JSON intact.
  static String resolveReference(String value, String? base) {
    if (base == null || !(value.startsWith('./') || value.startsWith('../'))) {
      return value;
    }
    final parts = value.split(';');
    parts[0] = Uri.parse(base).resolve(parts.first).toString();
    return parts.join(';');
  }

  Site copyWith({String? key, String? name, bool? isEnabled}) => Site(
    key: key ?? this.key,
    name: name ?? this.name,
    type: type,
    api: api,
    searchable: searchable,
    isEnabled: isEnabled ?? this.isEnabled,
    sourceKind: sourceKind,
    configUrl: configUrl,
    jar: jar,
    ext: ext,
    options: options,
    retiredBridge: retiredBridge,
  );
  Map<String, dynamic> toJson() => {
    ...options,
    'key': key,
    'name': name,
    'type': type,
    'api': api,
    'searchable': searchable,
    'isEnabled': isEnabled,
    'configUrl': configUrl,
    'jar': jar,
    'ext': ext,
    'retiredBridge': retiredBridge,
    if (isJar) 'upstreamKey': options['upstreamKey'] ?? options['key'] ?? key,
  };
  factory Site.fromCache(Map<String, dynamic> json) => Site.fromJson(json);
  static bool _isHttp(String api) =>
      api.startsWith('https://') || api.startsWith('http://');
  static bool _isScript(String api) {
    final path = Uri.tryParse(api)?.path.toLowerCase() ?? '';
    return path.endsWith('.js') || path.endsWith('.py');
  }

  static bool _boolLike(Object? value, {required bool defaultValue}) =>
      switch (value) {
        final bool flag => flag,
        final num number => number != 0,
        final String text when text == '1' || text.toLowerCase() == 'true' =>
          true,
        final String text when text == '0' || text.toLowerCase() == 'false' =>
          false,
        _ => defaultValue,
      };
}
