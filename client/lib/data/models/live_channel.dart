/// A channel in an IPTV playlist. EPG identifiers are retained for future use.
class LiveChannel {
  final String name;
  final String group;
  final String url;
  final String? logo;
  final String? tvgId;
  final Map<String, String> headers;

  const LiveChannel({
    required this.name,
    required this.group,
    required this.url,
    this.logo,
    this.tvgId,
    this.headers = const {},
  });

  String get identity => '$group\u0000$name\u0000$url';

  Map<String, dynamic> toJson() => {
    'name': name,
    'group': group,
    'url': url,
    'logo': logo,
    'tvgId': tvgId,
    'headers': headers,
  };

  factory LiveChannel.fromJson(Map<String, dynamic> json) => LiveChannel(
    name: json['name'] as String,
    group: json['group'] as String,
    url: json['url'] as String,
    logo: json['logo'] as String?,
    tvgId: json['tvgId'] as String?,
    headers: Map<String, String>.from(json['headers'] as Map? ?? const {}),
  );
}

class LivePlaylist {
  final List<LiveChannel> channels;
  final DateTime updatedAt;

  const LivePlaylist({required this.channels, required this.updatedAt});

  List<String> get groups => channels.map((c) => c.group).toSet().toList();
}

class LiveSubscription {
  final String? id;
  final String name;
  final String url;
  final bool isEnabled;
  final List<String> fallbackUrls;
  const LiveSubscription({
    required this.name,
    required this.url,
    this.id,
    this.isEnabled = true,
    this.fallbackUrls = const [],
  });
  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'url': url,
    'isEnabled': isEnabled,
    if (fallbackUrls.isNotEmpty) 'fallbackUrls': fallbackUrls,
  };
  factory LiveSubscription.fromJson(Map<String, dynamic> json) =>
      LiveSubscription(
        id: json['id'] as String?,
        name: json['name'] as String,
        url: json['url'] as String,
        isEnabled: json['isEnabled'] as bool? ?? true,
        fallbackUrls: List<String>.from(json['fallbackUrls'] as List? ?? []),
      );
}
