import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/local/source_storage.dart';
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

  const SourceGroup({
    required this.url,
    this.config,
    this.warehouses = const [],
    this.warehouseUrl,
    this.loading = false,
    this.error,
  });

  String get name => SourceStorage.nameOf(url);
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
          isEnabled: enabled[site.identity] ?? site.isEnabled,
        );
      }
    }
    return unique.values.toList();
  }

  List<Site> get activeSites =>
      allSites.where((s) => s.isEnabled && s.isSupported).toList();

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

  SourceLibraryNotifier(this.storage, this.parser)
    : super(const SourceLibrary());

  Future<void> restore() {
    if (_restored) return Future.value();
    return _restoring ??= _restore();
  }

  Future<void> _restore() async {
    await storage.initDefaultsIfEmpty();
    if (_disposed) return;
    state = SourceLibrary(
      groups: {
        for (final url in storage.getAll())
          url: SourceGroup(
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
    final urls = state.groups.keys
        .where((u) => !SourceParser.isCmsApiUrl(u))
        .toList();
    for (var i = 0; i < urls.length; i += 2) {
      if (_disposed) return;
      await Future.wait(urls.skip(i).take(2).map(refresh));
    }
  }

  Future<void> refresh(String url) async {
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
    final values = {...state.enabled, site.identity: enabled};
    state = state.copyWith(enabled: values);
    await storage.setSiteEnabled(values);
  }

  Future<void> selectHome(Site site) async {
    if (!site.isSupported) return;
    state = state.copyWith(homeIdentity: site.identity);
    await storage.setHomeSite(site.identity);
    if (!site.isEnabled) await setEnabled(site, true);
  }

  Future<void> remove(String url) async {
    _versions[url] = (_versions[url] ?? 0) + 1;
    final groups = {...state.groups}..remove(url);
    state = state.copyWith(groups: groups);
    await storage.remove(url);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
