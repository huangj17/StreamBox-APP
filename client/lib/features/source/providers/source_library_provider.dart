import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/official_sources.dart';
import '../../../data/local/source_storage.dart';
import '../../../data/models/official_source_catalog.dart';
import '../../../data/models/site.dart';
import '../../../data/models/source_config.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/sources/source_parser.dart';
import 'source_provider.dart';

class SourceGroup {
  final String url;
  final SourceConfig? config;
  final List<Warehouse> warehouses;
  final String? warehouseUrl;
  final bool loading;
  final String? error;
  final String? version;
  final DateTime? syncedAt;
  final bool usingFallback;

  const SourceGroup({
    required this.url,
    this.config,
    this.warehouses = const [],
    this.warehouseUrl,
    this.loading = false,
    this.error,
    this.version,
    this.syncedAt,
    this.usingFallback = false,
  });

  String get name => SourceStorage.nameOf(url);

  SourceGroup withStatus({bool loading = false, String? error}) => SourceGroup(
    url: url,
    config: config,
    warehouses: warehouses,
    warehouseUrl: warehouseUrl,
    loading: loading,
    error: error,
    version: version,
    syncedAt: syncedAt,
    usingFallback: usingFallback,
  );
}

class SourceLibrary {
  final Map<String, SourceGroup> groups;
  final Map<String, bool> enabled;
  final String? homeIdentity;

  const SourceLibrary({
    this.groups = const {},
    this.enabled = const {},
    this.homeIdentity,
  });

  /// 内置与集合共享同一接口时只保留一个身份，避免重复搜索/历史失联。
  List<Site> get allSites {
    final unique = <String, Site>{};
    final keys = <String>{};
    final ordered = [
      ...groups.values.where((g) => SourceStorage.isBuiltIn(g.url)),
      ...groups.values.where((g) => !SourceStorage.isBuiltIn(g.url)),
    ];
    for (final group in ordered) {
      for (var site in group.config?.sites ?? <Site>[]) {
        if (unique.containsKey(site.identity)) continue;
        if (!keys.add(site.key)) {
          site = site.copyWith(key: '${site.key}@${site.identity}');
        }
        unique[site.identity] = site.copyWith(
          isEnabled: SourceStorage.isBuiltIn(group.url)
              ? site.isEnabled && (enabled[site.identity] ?? true)
              : enabled[site.identity] ?? site.isEnabled,
        );
      }
    }
    return unique.values.toList();
  }

  List<Site> get activeSites =>
      allSites.where((s) => s.isEnabled && s.isSupported).toList();

  bool isOfficiallyDisabled(String identity) =>
      groups[SourceStorage.officialUrl]?.config?.sites.any(
        (site) => site.identity == identity && !site.isEnabled,
      ) ??
      false;

  SourceLibrary copyWith({
    Map<String, SourceGroup>? groups,
    Map<String, bool>? enabled,
    String? homeIdentity,
  }) => SourceLibrary(
    groups: groups ?? this.groups,
    enabled: enabled ?? this.enabled,
    homeIdentity: homeIdentity ?? this.homeIdentity,
  );
}

final sourceLibraryProvider =
    StateNotifierProvider<SourceLibraryNotifier, SourceLibrary>((ref) {
      return SourceLibraryNotifier(
        ref.watch(sourceStorageProvider),
        ref.watch(sourceParserProvider),
      );
    });

class SourceLibraryNotifier extends StateNotifier<SourceLibrary> {
  final SourceStorage storage;
  final SourceParser parser;
  final Map<String, int> _versions = {};
  Future<void>? _restoring;
  bool _restored = false;
  bool _disposed = false;
  Timer? _officialTimer;
  Future<void>? _officialRefresh;
  DateTime? _lastOfficialAttempt;
  bool _foreground = true;
  final DateTime Function() _now;

  SourceLibraryNotifier(this.storage, this.parser, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(const SourceLibrary());

  Future<void> restore() {
    if (_restored) return Future.value();
    return _restoring ??= _restore();
  }

  Future<void> _restore() async {
    await storage.initDefaultsIfEmpty();
    if (_disposed) return;
    final snapshot = storage.getOfficialSnapshot();
    state = SourceLibrary(
      groups: {
        for (final url in storage.getAll())
          url: url == SourceStorage.officialUrl
              ? SourceGroup(
                  url: url,
                  config: (snapshot?.catalog ?? OfficialSourceCatalog.bundled)
                      .config,
                  version: snapshot?.catalog.version,
                  syncedAt: snapshot?.syncedAt,
                  usingFallback: snapshot == null,
                )
              : SourceGroup(
                  url: url,
                  config: SourceParser.isCmsApiUrl(url)
                      ? _direct(url)
                      : storage.getCachedConfig(url),
                  warehouseUrl: storage.getSelectedWarehouse(url),
                ),
      },
      enabled: storage.getSiteEnabled(),
      homeIdentity: storage.getHomeSite(),
    );
    _restored = true;
    _startOfficialTimer();
    // 缓存立即可用，后台限并发刷新远程集合。
    unawaited(refreshAll());
  }

  SourceConfig _direct(String url) {
    final config = SourceParser.wrapCmsUrl(url);
    return SourceConfig(
      sites: config.sites
          .map((s) => s.copyWith(name: SourceStorage.nameOf(url)))
          .toList(),
    );
  }

  Future<void> add(String url) async {
    await restore();
    await storage.add(url);
    if (_disposed) return;
    if (!state.groups.containsKey(url)) {
      state = state.copyWith(
        groups: {
          ...state.groups,
          url: SourceGroup(url: url),
        },
      );
    }
    await refresh(url);
  }

  Future<void> refreshAll() async {
    final urls = [
      // Do not let a long list of slow custom subscriptions delay the official
      // startup update. Its URL need not look like a JSON filename.
      if (state.groups.containsKey(SourceStorage.officialUrl))
        SourceStorage.officialUrl,
      ...state.groups.keys.where(
        (u) => u != SourceStorage.officialUrl && !SourceParser.isCmsApiUrl(u),
      ),
    ];
    for (var i = 0; i < urls.length; i += 2) {
      if (_disposed) return;
      await Future.wait(urls.skip(i).take(2).map(refresh));
    }
  }

  Future<void> refresh(String url) async {
    if (url == SourceStorage.officialUrl) {
      return _officialRefresh ??= _refreshOfficial().whenComplete(() {
        _officialRefresh = null;
      });
    }
    final previous = state.groups[url];
    if (previous == null) return;
    final version = (_versions[url] ?? 0) + 1;
    _versions[url] = version;
    bool current() =>
        !_disposed &&
        _versions[url] == version &&
        state.groups.containsKey(url);
    state = state.copyWith(
      groups: {
        ...state.groups,
        url: SourceGroup(
          url: url,
          config: previous.config,
          warehouses: previous.warehouses,
          warehouseUrl: previous.warehouseUrl,
          loading: true,
        ),
      },
    );
    try {
      SourceConfig? config;
      List<Warehouse> warehouses = [];
      String? warehouseUrl = previous.warehouseUrl;
      if (SourceParser.isCmsApiUrl(url)) {
        config = _direct(url);
      } else if (SourceParser.isJarBridgeUrl(url)) {
        config = await parser.parseJarBridge(url);
      } else {
        final gateway = SourceParser.shouldProbeGateway(url)
            ? await parser.probeGateway(url)
            : null;
        if (gateway != null) {
          config = gateway;
        } else {
          final document = await parser.parseDocument(url);
          warehouses = document.warehouses;
          config = document.config;
          if (warehouses.isNotEmpty) {
            if (!warehouses.any((w) => w.url == warehouseUrl)) {
              warehouseUrl = null;
            }
            if (warehouseUrl != null) {
              config = SourceParser.isCmsApiUrl(warehouseUrl)
                  ? _direct(warehouseUrl)
                  : await parser.parse(warehouseUrl);
            }
          }
        }
      }
      if (!current()) return;
      if (config != null && config.sites.isEmpty) {
        throw const FormatException('配置中没有片源');
      }
      if (config != null) await storage.cacheConfig(url, config);
      if (config == null) await storage.clearCachedConfig(url);
      if (!current()) return;
      state = state.copyWith(
        groups: {
          ...state.groups,
          url: SourceGroup(
            url: url,
            config: config,
            warehouses: warehouses,
            warehouseUrl: warehouseUrl,
          ),
        },
      );
    } catch (error) {
      if (!current()) return;
      state = state.copyWith(
        groups: {
          ...state.groups,
          url: SourceGroup(
            url: url,
            config: previous.config,
            warehouses: previous.warehouses,
            warehouseUrl: previous.warehouseUrl,
            error: previous.config == null
                ? '加载失败：$error'
                : '更新失败，保留已保存的片源：$error',
          ),
        },
      );
    }
  }

  /// Resume is throttled by attempts (including failures), so switching windows
  /// or an unavailable server cannot create a tight request loop.
  Future<void> refreshOfficialIfStale() async {
    if (!_restored || _disposed || !_foreground) return;
    final last = _lastOfficialAttempt;
    if (last != null &&
        _now().difference(last) < OfficialSources.refreshInterval) {
      return;
    }
    await refresh(SourceStorage.officialUrl);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _officialTimer?.cancel();
    _officialTimer = null;
    if (foreground && !_disposed) {
      _startOfficialTimer();
      unawaited(refreshOfficialIfStale());
    }
  }

  void _startOfficialTimer() {
    if (!_foreground || !_restored || _disposed) return;
    _officialTimer ??= Timer.periodic(OfficialSources.refreshInterval, (_) {
      unawaited(refreshOfficialIfStale());
    });
  }

  Future<void> _refreshOfficial() async {
    const url = SourceStorage.officialUrl;
    final previous = state.groups[url];
    if (_disposed || previous == null) return;
    _lastOfficialAttempt = _now();
    state = state.copyWith(
      groups: {...state.groups, url: previous.withStatus(loading: true)},
    );
    try {
      final catalog = await parser.parseOfficialCatalog();
      if (_disposed) return;
      final syncedAt = _now();
      await storage.saveOfficialSnapshot(
        OfficialSourceSnapshot(catalog, syncedAt),
      );
      if (_disposed) return;

      // Read the latest preferences once: a rollback must overwrite stale URL
      // entries, and address swaps must not read values already moved this round.
      final previousEnabled = state.enabled;
      final enabled = {...previousEnabled};
      final previousHome = state.homeIdentity;
      var home = previousHome;
      final oldByKey = {
        for (final s in previous.config?.sites ?? <Site>[]) s.key: s,
      };
      for (final site in catalog.config.sites) {
        final old = oldByKey[site.key];
        if (old == null || old.identity == site.identity) continue;
        enabled[site.identity] = previousEnabled[old.identity] ?? true;
        // Compare against the original selection, never a migrated destination.
        if (previousHome == old.identity) home = site.identity;
      }
      final preferencesChanged = enabled.entries.any(
        (entry) => previousEnabled[entry.key] != entry.value,
      );
      final homeChanged = home != state.homeIdentity;
      state = state.copyWith(
        enabled: enabled,
        homeIdentity: home,
        groups: {
          ...state.groups,
          url: SourceGroup(
            url: url,
            config: catalog.config,
            version: catalog.version,
            syncedAt: syncedAt,
          ),
        },
      );
      await Future.wait([
        if (preferencesChanged) storage.setSiteEnabled(enabled),
        if (homeChanged && home != null) storage.setHomeSite(home),
      ]);
    } catch (error) {
      if (_disposed) return;
      final current = state.groups[url]!;
      state = state.copyWith(
        groups: {
          ...state.groups,
          url: current.withStatus(
            error: current.usingFallback
                ? '更新失败，使用本地兜底片源：$error'
                : '更新失败，保留上次成功配置：$error',
          ),
        },
      );
    }
  }

  Future<void> selectWarehouse(String url, String warehouseUrl) async {
    final group = state.groups[url];
    if (group == null) return;
    _versions[url] = (_versions[url] ?? 0) + 1;
    state = state.copyWith(
      groups: {
        ...state.groups,
        url: SourceGroup(
          url: url,
          warehouses: group.warehouses,
          warehouseUrl: warehouseUrl,
        ),
      },
    );
    await storage.clearCachedConfig(url);
    await storage.setSelectedWarehouse(url, warehouseUrl);
    await refresh(url);
  }

  Future<void> setEnabled(Site site, bool enabled) async {
    if (enabled && state.isOfficiallyDisabled(site.identity)) return;
    final values = {...state.enabled, site.identity: enabled};
    state = state.copyWith(enabled: values);
    await storage.setSiteEnabled(values);
  }

  Future<void> selectHome(Site site) async {
    if (!site.isSupported || state.isOfficiallyDisabled(site.identity)) return;
    state = state.copyWith(homeIdentity: site.identity);
    await storage.setHomeSite(site.identity);
    if (!site.isEnabled) await setEnabled(site, true);
  }

  Future<void> remove(String url) async {
    if (url == SourceStorage.officialUrl) return;
    _versions[url] = (_versions[url] ?? 0) + 1;
    final groups = {...state.groups}..remove(url);
    state = state.copyWith(groups: groups);
    await storage.remove(url);
  }

  @override
  void dispose() {
    _disposed = true;
    _officialTimer?.cancel();
    super.dispose();
  }
}
