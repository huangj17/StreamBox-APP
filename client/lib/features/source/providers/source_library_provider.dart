import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/official_sources.dart';
import '../../../core/network/source_error_message.dart';
import '../../../data/local/source_storage.dart';
import '../../../data/models/official_source_catalog.dart';
import '../../../data/models/site.dart';
import '../../../data/models/source_config.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/sources/source_parser.dart';
import 'source_provider.dart';

class SourceGroup {
  final String url;
  final String? title;
  final SourceConfig? config;
  final List<Warehouse> warehouses;
  final String? warehouseUrl;
  final bool loading;
  final String? error;
  final String? errorDetails;
  final String? version;
  final DateTime? syncedAt;

  const SourceGroup({
    required this.url,
    this.title,
    this.config,
    this.warehouses = const [],
    this.warehouseUrl,
    this.loading = false,
    this.error,
    this.errorDetails,
    this.version,
    this.syncedAt,
  });

  String get name => title ?? SourceStorage.nameOf(url);

  /// A successfully synced empty catalog is distinct from having no cache.
  bool get needsInitialSync => SourceStorage.isBuiltIn(url) && config == null;

  SourceGroup withStatus({
    bool loading = false,
    String? error,
    String? errorDetails,
  }) => SourceGroup(
    url: url,
    title: title,
    config: config,
    warehouses: warehouses,
    warehouseUrl: warehouseUrl,
    loading: loading,
    error: error,
    errorDetails: errorDetails,
    version: version,
    syncedAt: syncedAt,
  );
}

class SourceLibrary {
  final Map<String, SourceGroup> groups;
  final Map<String, bool> enabled;
  final String? homeIdentity;
  final SourceGroup? catalogStatus;

  const SourceLibrary({
    this.groups = const {},
    this.enabled = const {},
    this.homeIdentity,
    this.catalogStatus,
  });

  /// 官方与集合共享同一接口时只保留一个身份，避免重复搜索/历史失联。
  List<Site> get allSites {
    final unique = <String, Site>{};
    final keys = <String>{};
    final ordered = [
      ...groups.values.where((g) => SourceStorage.isBuiltIn(g.url)),
      ...groups.values.where((g) => !SourceStorage.isBuiltIn(g.url)),
    ];
    // Canonical source/history keys must not depend on the display order.
    final canonicalOrder = [...ordered]
      ..sort((a, b) {
        final aBuiltIn = SourceStorage.isBuiltIn(a.url);
        final bBuiltIn = SourceStorage.isBuiltIn(b.url);
        if (aBuiltIn != bBuiltIn) return aBuiltIn ? -1 : 1;
        return a.url.compareTo(b.url);
      });
    for (final group in canonicalOrder) {
      for (var site in group.config?.sites ?? <Site>[]) {
        if (!site.isVisible || unique.containsKey(site.identity)) continue;
        if (!keys.add(site.key)) {
          final scoped = '${site.key}@${group.url}';
          site = site.copyWith(
            key: keys.add(scoped) ? scoped : '$scoped@${site.identity}',
          );
        }
        unique[site.identity] = site.copyWith(
          isEnabled:
              !isOfficiallyDisabled(site.identity) &&
              (SourceStorage.isBuiltIn(group.url)
                  ? site.isEnabled && (enabled[site.identity] ?? true)
                  : enabled[site.identity] ?? site.isEnabled),
        );
      }
    }
    final seen = <String>{};
    return [
      for (final group in ordered)
        for (final site in group.config?.sites ?? <Site>[])
          if (site.isVisible && seen.add(site.identity)) unique[site.identity]!,
    ];
  }

  List<Site> get activeSites =>
      allSites.where((s) => s.isEnabled && s.isSupported).toList();

  List<SourceGroup> originsFor(String identity) => groups.values
      .where(
        (group) =>
            group.config?.sites.any((s) => s.identity == identity) ?? false,
      )
      .toList();

  bool isOfficiallyDisabled(String identity) => groups.values
      .where((group) => SourceStorage.isBuiltIn(group.url))
      .any(
        (group) =>
            group.config?.sites.any(
              (site) => site.identity == identity && !site.isEnabled,
            ) ??
            false,
      );

  SourceLibrary copyWith({
    Map<String, SourceGroup>? groups,
    Map<String, bool>? enabled,
    String? homeIdentity,
    SourceGroup? catalogStatus,
  }) => SourceLibrary(
    groups: groups ?? this.groups,
    enabled: enabled ?? this.enabled,
    homeIdentity: homeIdentity ?? this.homeIdentity,
    catalogStatus: catalogStatus ?? this.catalogStatus,
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
  final Map<String, Future<void>> _refreshes = {};
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
    if (snapshot != null) await _importCatalogSources(snapshot.catalog);
    if (_disposed) return;
    state = SourceLibrary(
      groups: {
        if (snapshot != null) ..._catalogGroups(snapshot),
        if (snapshot == null)
          SourceStorage.officialUrl: const SourceGroup(
            url: SourceStorage.officialUrl,
          ),
        for (final url in storage.getAll())
          if (!SourceStorage.isBuiltIn(url) &&
              !(snapshot?.catalog.groups.any((group) => group.url == url) ??
                  false))
            url: _restoreGroup(url),
      },
      enabled: storage.getSiteEnabled(),
      homeIdentity: storage.getHomeSite(),
      catalogStatus: SourceGroup(
        url: SourceStorage.officialUrl,
        config: snapshot?.catalog.config,
        version: snapshot?.catalog.version,
        syncedAt: snapshot?.syncedAt,
      ),
    );
    _restored = true;
    _startOfficialTimer();
    // 缓存立即可用，后台限并发刷新远程集合。
    unawaited(refreshAll());
  }

  Future<void> _importCatalogSources(OfficialSourceCatalog catalog) async {
    for (final group in catalog.groups.where((group) => !group.isInline)) {
      await storage.importCatalogSource(group.url, group.title);
    }
  }

  SourceGroup _restoreGroup(String url) => SourceGroup(
    url: url,
    title: storage.getName(url),
    config: SourceParser.isCmsApiUrl(url)
        ? _direct(url)
        : storage.getCachedConfig(url),
    warehouseUrl: storage.getSelectedWarehouse(url),
  );

  Map<String, SourceGroup> _catalogGroups(
    OfficialSourceSnapshot snapshot, {
    Map<String, SourceGroup> previous = const {},
  }) {
    final subscribed = storage.getAll().toSet();
    final result = <String, SourceGroup>{};
    for (final entry in snapshot.catalog.groups) {
      if (entry.isInline) {
        result[entry.url] = SourceGroup(
          url: entry.url,
          title: entry.title,
          config: entry.config,
          version: snapshot.catalog.version,
          syncedAt: snapshot.syncedAt,
        );
      } else if (subscribed.contains(entry.url)) {
        final group = previous[entry.url] ?? _restoreGroup(entry.url);
        result[entry.url] = SourceGroup(
          url: entry.url,
          title: entry.title,
          config: group.config,
          warehouses: group.warehouses,
          warehouseUrl: group.warehouseUrl,
          loading: group.loading,
          error: group.error,
          errorDetails: group.errorDetails,
        );
      }
    }
    return result;
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
          url: SourceGroup(url: url, title: storage.getName(url)),
        },
      );
    }
    await refresh(url);
  }

  Future<void> refreshAll() async {
    final existingUrls = state.groups.keys.toList();
    // The catalog creates independent subscriptions before they are refreshed.
    await refresh(SourceStorage.officialUrl);
    if (_disposed) return;
    final importedUrls =
        storage
            .getOfficialSnapshot()
            ?.catalog
            .groups
            .where((group) => !group.isInline)
            .map((group) => group.url) ??
        <String>[];
    final urls = [
      ...{...existingUrls, ...importedUrls}.where(
        (u) =>
            state.groups.containsKey(u) &&
            !SourceStorage.isBuiltIn(u) &&
            !SourceParser.isCmsApiUrl(u),
      ),
    ];
    await _refreshUrls(urls);
  }

  Future<void> _refreshUrls(List<String> urls) async {
    for (var i = 0; i < urls.length; i += 2) {
      if (_disposed) return;
      await Future.wait(urls.skip(i).take(2).map(refresh));
    }
  }

  Future<void> refresh(String url) {
    if (_disposed) return Future.value();
    if (SourceStorage.isBuiltIn(url)) {
      return _officialRefresh ??= _refreshOfficial().whenComplete(() {
        _officialRefresh = null;
      });
    }
    final existing = _refreshes[url];
    if (existing != null) return existing;
    late final Future<void> job;
    job = _refreshOne(url).whenComplete(() {
      if (identical(_refreshes[url], job)) _refreshes.remove(url);
    });
    return _refreshes[url] = job;
  }

  Future<void> _refreshOne(String url) async {
    final previous = state.groups[url];
    if (previous == null) return;
    final version = (_versions[url] ?? 0) + 1;
    _versions[url] = version;
    bool current() =>
        !_disposed &&
        _versions[url] == version &&
        state.groups.containsKey(url);
    state = state.copyWith(
      groups: {...state.groups, url: previous.withStatus(loading: true)},
    );
    try {
      SourceConfig? config;
      List<Warehouse> warehouses = [];
      String? warehouseUrl = previous.warehouseUrl;
      if (SourceParser.isCmsApiUrl(url)) {
        config = _direct(url);
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
            title: previous.title,
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
            title: previous.title,
            config: previous.config,
            warehouses: previous.warehouses,
            warehouseUrl: previous.warehouseUrl,
            error: previous.config == null
                ? '加载失败：${sourceErrorMessage(error)}'
                : '更新失败，保留已保存的片源：${sourceErrorMessage(error)}',
            errorDetails: error.toString(),
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
    if (_disposed) return;
    final previousSnapshot = storage.getOfficialSnapshot();
    final previous =
        state.catalogStatus ??
        state.groups[url] ??
        SourceGroup(
          url: url,
          config: previousSnapshot?.catalog.config,
          version: previousSnapshot?.catalog.version,
          syncedAt: previousSnapshot?.syncedAt,
        );
    final previousGroups = state.groups;
    _lastOfficialAttempt = _now();
    state = state.copyWith(
      catalogStatus: previous.withStatus(
        loading: true,
        error: previous.error,
        errorDetails: previous.errorDetails,
      ),
      groups: {
        for (final group in state.groups.values)
          group.url: SourceStorage.isBuiltIn(group.url)
              ? group.withStatus(loading: true)
              : group,
      },
    );
    try {
      final catalog = await parser.parseOfficialCatalog();
      if (_disposed) return;
      final syncedAt = _now();
      final snapshot = OfficialSourceSnapshot(catalog, syncedAt);
      await storage.saveOfficialSnapshot(snapshot);
      await _importCatalogSources(catalog);
      if (_disposed) return;

      // Read the latest preferences once: a rollback must overwrite stale URL
      // entries, and address swaps must not read values already moved this round.
      final previousEnabled = state.enabled;
      final enabled = {...previousEnabled};
      final previousHome = state.homeIdentity;
      var home = previousHome;
      final legacyByKey = {
        for (final site in previousGroups[url]?.config?.sites ?? <Site>[])
          site.key: site,
      };
      final keyCounts = <String, int>{};
      for (final site in catalog.config.sites) {
        keyCounts.update(site.key, (count) => count + 1, ifAbsent: () => 1);
      }
      for (final group in catalog.groups.where((group) => group.isInline)) {
        final oldByKey = {
          for (final s in previousGroups[group.url]?.config?.sites ?? <Site>[])
            s.key: s,
        };
        for (final site in group.config!.sites) {
          final old =
              oldByKey[site.key] ??
              (keyCounts[site.key] == 1 ? legacyByKey[site.key] : null);
          if (old == null || old.identity == site.identity) continue;
          enabled[site.identity] = previousEnabled[old.identity] ?? true;
          // Compare against the original selection, never a migrated destination.
          if (previousHome == old.identity) home = site.identity;
        }
      }
      final preferencesChanged = enabled.entries.any(
        (entry) => previousEnabled[entry.key] != entry.value,
      );
      final homeChanged = home != state.homeIdentity;
      final groups = _catalogGroups(snapshot, previous: state.groups);
      state = state.copyWith(
        catalogStatus: SourceGroup(
          url: url,
          config: catalog.config,
          version: catalog.version,
          syncedAt: syncedAt,
        ),
        enabled: enabled,
        homeIdentity: home,
        groups: {
          ...groups,
          for (final group in state.groups.values)
            if (!SourceStorage.isBuiltIn(group.url) &&
                !groups.containsKey(group.url))
              group.url: group,
        },
      );
      await Future.wait([
        if (preferencesChanged) storage.setSiteEnabled(enabled),
        if (homeChanged && home != null) storage.setHomeSite(home),
      ]);
    } catch (error) {
      if (_disposed) return;
      final failure = previous.withStatus(
        error: previous.needsInitialSync
            ? '更新失败，暂无本地缓存：${sourceErrorMessage(error)}'
            : '更新失败，保留上次成功配置：${sourceErrorMessage(error)}',
        errorDetails: error.toString(),
      );
      state = state.copyWith(
        catalogStatus: failure,
        groups: {
          for (final group in state.groups.values)
            group.url: SourceStorage.isBuiltIn(group.url)
                ? group.withStatus(
                    error: failure.error,
                    errorDetails: failure.errorDetails,
                  )
                : group,
        },
      );
    }
    if (_disposed) return;
    // Each remote configuration owns its cache, warehouses and error/retry state.
    // A failed third-party download must not invalidate the catalog snapshot.
    final remoteUrls =
        storage
            .getOfficialSnapshot()
            ?.catalog
            .groups
            .where(
              (group) => !group.isInline && state.groups.containsKey(group.url),
            )
            .map((group) => group.url)
            .toList() ??
        <String>[];
    unawaited(_refreshUrls(remoteUrls));
  }

  Future<void> selectWarehouse(String url, String warehouseUrl) async {
    final group = state.groups[url];
    if (group == null) return;
    _versions[url] = (_versions[url] ?? 0) + 1;
    _refreshes.remove(url);
    state = state.copyWith(
      groups: {
        ...state.groups,
        url: SourceGroup(
          url: url,
          title: group.title,
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
    if (SourceStorage.isBuiltIn(url)) return;
    _versions[url] = (_versions[url] ?? 0) + 1;
    _refreshes.remove(url);
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
