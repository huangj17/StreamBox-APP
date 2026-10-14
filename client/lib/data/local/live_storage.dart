import 'dart:convert';
import 'package:hive/hive.dart';
import '../models/live_channel.dart';
import '../models/live_source_catalog.dart';
import '../../core/config/live_sources.dart';

class LiveStorage {
  late Box<String> _box;

  Future<void> init() async {
    _box = await Hive.openBox<String>('live_subscriptions');
    final existing = _box.containsKey('subscriptions');
    if (!existing) await saveSubscriptions([]);
    if (!_box.containsKey('remote_catalog_migrated_v1')) {
      final items = subscriptions;
      final hidden = <String>{};
      if (existing) {
        for (final entry in LiveSources.legacyIds.entries) {
          if (!items.any((s) => s.url == entry.key)) hidden.add(entry.value);
        }
      }
      await _box.putAll({
        'subscriptions': jsonEncode([
          for (final item in items)
            {
              ...item.toJson(),
              if (item.id == null &&
                  LiveSources.legacyIds.containsKey(item.url))
                'id': LiveSources.legacyIds[item.url],
            },
        ]),
        'hidden_official': jsonEncode(hidden.toList()),
        'remote_catalog_migrated_v1': 'done',
      });
    }
  }

  Set<String> get hiddenOfficialIds {
    try {
      return Set<String>.from(
        jsonDecode(_box.get('hidden_official') ?? '[]') as List,
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> hideOfficial(String id) => _box.put(
    'hidden_official',
    jsonEncode({...hiddenOfficialIds, id}.toList()),
  );
  Future<void> restoreOfficial() => _box.put('hidden_official', '[]');
  LiveSourceCatalog? get officialCatalog {
    try {
      final raw = _box.get('official_catalog');
      return raw == null ? null : LiveSourceCatalog.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  DateTime? get officialSyncedAt =>
      DateTime.tryParse(_box.get('official_synced_at') ?? '');

  /// Replace server-managed rows only. Stable IDs migrate cache and history;
  /// read all old values before writes so address swaps cannot overwrite them.
  Future<void> applyCatalog(
    LiveSourceCatalog catalog, {
    String? currentSelected,
  }) {
    final previous = subscriptions;
    final custom = previous.where((s) => s.id == null).toList();
    final customUrls = custom.map((s) => s.url).toSet();
    final oldById = {
      for (final s in officialCatalog?.subscriptions ?? <LiveSubscription>[])
        s.id: s,
      for (final s in previous.where((s) => s.id != null)) s.id: s,
    };
    final active = catalog.subscriptions
        .where(
          (s) =>
              s.isEnabled &&
              !hiddenOfficialIds.contains(s.id) &&
              !customUrls.contains(s.url),
        )
        .toList();
    final items = [...active, ...custom];
    final writes = <String, String>{};
    var selected = currentSelected ?? selectedUrl;
    var watched = lastPlayedUrl;
    for (final item in active) {
      final old = oldById[item.id];
      if (old == null || old.url == item.url) continue;
      for (final prefix in ['cache:', 'channel:']) {
        final value = _box.get('$prefix${old.url}');
        if (value != null && !customUrls.contains(item.url)) {
          if (prefix == 'cache:') {
            try {
              final cache = jsonDecode(value) as Map<String, dynamic>;
              // This is a fallback borrowed from the old endpoint, not a
              // successful download of the new M3U. Fetch the new list now.
              cache['updatedAt'] = DateTime.fromMillisecondsSinceEpoch(
                0,
              ).toIso8601String();
              writes['$prefix${item.url}'] = jsonEncode(cache);
            } catch (_) {
              // Corrupt old cache must not prevent a valid catalog update.
            }
          } else {
            writes['$prefix${item.url}'] = value;
          }
        }
      }
      if (!customUrls.contains(old.url)) {
        if ((currentSelected ?? selectedUrl) == old.url) selected = item.url;
        if (lastPlayedUrl == old.url) watched = item.url;
      }
    }
    if (!items.any((s) => s.url == selected)) selected = items.firstOrNull?.url;
    writes.addAll({
      'subscriptions': jsonEncode(items.map((s) => s.toJson()).toList()),
      'official_catalog': jsonEncode(catalog.toJson()),
      'official_synced_at': DateTime.now().toIso8601String(),
      'selected': selected ?? '',
      'last_played_subscription': ?watched,
    });
    return _box.putAll(writes);
  }

  List<LiveSubscription> get subscriptions {
    try {
      return (jsonDecode(_box.get('subscriptions') ?? '[]') as List)
          .map((e) => LiveSubscription.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSubscriptions(List<LiveSubscription> items) => _box.put(
    'subscriptions',
    jsonEncode(items.map((s) => s.toJson()).toList()),
  );

  String? get selectedUrl {
    final value = _box.get('selected');
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> select(String? url) =>
      url == null ? _box.delete('selected') : _box.put('selected', url);

  LivePlaylist? cached(String url) {
    try {
      final raw = _box.get('cache:$url');
      if (raw == null) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return LivePlaylist(
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        channels: (json['channels'] as List)
            .map((e) => LiveChannel.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> cache(String url, LivePlaylist playlist) => _box.put(
    'cache:$url',
    jsonEncode({
      'updatedAt': playlist.updatedAt.toIso8601String(),
      'channels': playlist.channels.map((c) => c.toJson()).toList(),
    }),
  );

  Future<void> removeCache(String url) async {
    await _box.delete('cache:$url');
    await _box.delete('channel:$url');
    if (lastPlayedUrl == url) await _box.delete('last_played_subscription');
  }

  String? get lastPlayedUrl => _box.get('last_played_subscription');

  String? lastChannel(String url) => lastChannelDetails(url)?.identity;

  LiveChannel? lastChannelDetails(String url) {
    final raw = _box.get('channel:$url');
    if (raw == null) return null;
    try {
      return LiveChannel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      // Older installs saved group/name/URL as one identity string. Retain
      // that history and resolve the channel even if its URL has changed.
      final parts = raw.split('\u0000');
      if (parts.length != 3) return null;
      return LiveChannel(group: parts[0], name: parts[1], url: parts[2]);
    }
  }

  Future<void> rememberChannel(String url, LiveChannel channel) => _box.putAll({
    'channel:$url': jsonEncode(channel.toJson()),
    'last_played_subscription': url,
  });
}
