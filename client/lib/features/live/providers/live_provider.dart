import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/source_error_message.dart';
import '../../../core/network/url_policy.dart';
import '../../../data/live/live_repository.dart';
import '../../../data/local/live_storage.dart';
import '../../../data/models/live_channel.dart';
import '../../../core/config/live_sources.dart';
import '../../home/providers/categories_provider.dart';

final liveStorageProvider = Provider<LiveStorage>(
  (_) => throw UnimplementedError('liveStorageProvider must be overridden'),
);
final liveRepositoryProvider = Provider(
  (ref) => LiveRepository(ref.watch(dioProvider)),
);
final liveProvider = StateNotifierProvider<LiveNotifier, LiveState>(
  (ref) => LiveNotifier(
    ref.watch(liveStorageProvider),
    ref.watch(liveRepositoryProvider),
  ),
);

class LiveState {
  final List<LiveSubscription> subscriptions;
  final String? selectedUrl;
  final Map<String, LivePlaylist> playlists;
  final Set<String> loading;
  final Map<String, String> errors;
  final bool catalogLoading;
  final String? catalogError;
  final DateTime? catalogSyncedAt;
  final int hiddenOfficialCount;
  const LiveState({
    this.subscriptions = const [],
    this.selectedUrl,
    this.playlists = const {},
    this.loading = const {},
    this.errors = const {},
    this.catalogLoading = false,
    this.catalogError,
    this.catalogSyncedAt,
    this.hiddenOfficialCount = 0,
  });

  LiveSubscription? get selected {
    for (final item in subscriptions) {
      if (item.url == selectedUrl) return item;
    }
    return null;
  }

  LivePlaylist? get playlist => playlists[selectedUrl];

  LiveState copyWith({
    List<LiveSubscription>? subscriptions,
    String? selectedUrl,
    bool clearSelection = false,
    Map<String, LivePlaylist>? playlists,
    Set<String>? loading,
    Map<String, String>? errors,
    bool? catalogLoading,
    String? catalogError,
    bool clearCatalogError = false,
    DateTime? catalogSyncedAt,
    int? hiddenOfficialCount,
  }) => LiveState(
    subscriptions: subscriptions ?? this.subscriptions,
    selectedUrl: clearSelection ? null : selectedUrl ?? this.selectedUrl,
    playlists: playlists ?? this.playlists,
    loading: loading ?? this.loading,
    errors: errors ?? this.errors,
    catalogLoading: catalogLoading ?? this.catalogLoading,
    catalogError: clearCatalogError ? null : catalogError ?? this.catalogError,
    catalogSyncedAt: catalogSyncedAt ?? this.catalogSyncedAt,
    hiddenOfficialCount: hiddenOfficialCount ?? this.hiddenOfficialCount,
  );
}

class LiveNotifier extends StateNotifier<LiveState> {
  final LiveStorage storage;
  final LiveRepository repository;
  final _tokens = <String, CancelToken>{};
  final _jobs = <String, Future<void>>{};
  Future<void> _mutations = Future.value();
  Future<void>? _catalogJob;
  CancelToken? _catalogToken;
  DateTime? _lastCatalogAttempt;
  Timer? _catalogTimer;

  LiveNotifier(this.storage, this.repository) : super(const LiveState()) {
    final items = storage.subscriptions;
    final selected =
        items.where((s) => s.url == storage.lastPlayedUrl).firstOrNull ??
        items.where((s) => s.url == storage.selectedUrl).firstOrNull ??
        items.firstOrNull;
    state = LiveState(
      subscriptions: items,
      selectedUrl: selected?.url,
      catalogSyncedAt: storage.officialSyncedAt,
      hiddenOfficialCount: storage.hiddenOfficialIds.length,
      playlists: {
        for (final item in items)
          if (storage.cached(item.url) case final LivePlaylist cached)
            item.url: cached,
      },
    );
  }

  Future<T> _mutate<T>(Future<T> Function() operation) {
    final result = _mutations.then((_) => operation());
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> syncCatalog({bool force = false}) {
    if (!mounted) return Future.value();
    if (_catalogJob != null) return _catalogJob!;
    final last = _lastCatalogAttempt ?? state.catalogSyncedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < LiveSources.refreshInterval) {
      return Future.value();
    }
    _lastCatalogAttempt = DateTime.now();
    final completion = Completer<void>();
    _catalogJob = completion.future;
    final token = CancelToken();
    _catalogToken = token;
    unawaited(
      _syncCatalog(
        token,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  void setForeground(bool foreground) {
    if (!mounted) return;
    if (!foreground) {
      _catalogTimer?.cancel();
      _catalogTimer = null;
      return;
    }
    _catalogTimer ??= Timer.periodic(LiveSources.refreshInterval, (_) {
      unawaited(syncCatalog(force: true));
    });
    unawaited(syncCatalog());
  }

  void _loadAppliedCatalog() {
    final items = storage.subscriptions;
    final available = items.map((s) => s.url).toSet();
    for (final url in _tokens.keys.toList()) {
      if (!available.contains(url)) {
        _tokens.remove(url)?.cancel('直播配置已变更');
        _jobs.remove(url);
      }
    }
    final selected = storage.selectedUrl;
    state = state.copyWith(
      subscriptions: items,
      selectedUrl: selected,
      clearSelection: selected == null,
      playlists: {
        for (final item in items)
          if (storage.cached(item.url) case final LivePlaylist cache)
            item.url: cache,
      },
      loading: state.loading.intersection(available),
      errors: {
        for (final entry in state.errors.entries)
          if (available.contains(entry.key) &&
              storage.cached(entry.key)?.updatedAt.millisecondsSinceEpoch != 0)
            entry.key: entry.value,
      },
      catalogSyncedAt: storage.officialSyncedAt,
      hiddenOfficialCount: storage.hiddenOfficialIds.length,
    );
  }

  Future<void> _syncCatalog(CancelToken token) async {
    state = state.copyWith(catalogLoading: true, clearCatalogError: true);
    try {
      final catalog = await repository.fetchCatalog(cancelToken: token);
      if (!mounted || token.isCancelled) return;
      await _mutate(() async {
        if (!mounted || token.isCancelled) return;
        await storage.applyCatalog(catalog, currentSelected: state.selectedUrl);
        if (mounted && !token.isCancelled) _loadAppliedCatalog();
      });
      final selected = mounted ? state.selectedUrl : null;
      if (selected != null) unawaited(refreshIfStale(selected));
    } catch (error) {
      if (mounted && !token.isCancelled) {
        state = state.copyWith(
          catalogError:
              '${state.subscriptions.isEmpty ? '暂未加载直播配置' : '更新失败，继续使用缓存'}：${sourceErrorMessage(error)}',
        );
      }
    } finally {
      _catalogJob = null;
      _catalogToken = null;
      if (mounted) state = state.copyWith(catalogLoading: false);
      token.cancel('直播配置请求已完成');
    }
  }

  Future<void> restoreOfficial() async {
    await _mutate(() async {
      await storage.restoreOfficial();
      final catalog = storage.officialCatalog;
      if (catalog != null) {
        await storage.applyCatalog(catalog, currentSelected: state.selectedUrl);
      }
      if (mounted) _loadAppliedCatalog();
    });
    await syncCatalog(force: true);
  }

  Future<void> select(String url) async {
    final selected = await _mutate(() async {
      if (!mounted || !state.subscriptions.any((s) => s.url == url)) {
        return false;
      }
      state = state.copyWith(selectedUrl: url);
      await storage.select(url);
      return true;
    });
    if (selected && mounted) await refreshIfStale(url);
  }

  Future<void> refreshIfStale(String url) async {
    final cached = state.playlists[url];
    if (cached == null ||
        DateTime.now().difference(cached.updatedAt) >
            const Duration(hours: 6)) {
      await refresh(url);
    }
  }

  Future<void> add(String name, String rawUrl) async {
    name = name.trim();
    if (name.isEmpty || name.length > 100) {
      throw const FormatException('订阅名称需为 1–100 个字符');
    }
    final url = UrlPolicy.requireConfigUrl(rawUrl.trim()).toString();
    await _mutate(() async {
      if (!mounted || state.subscriptions.any((s) => s.url == url)) return;
      final items = [
        ...state.subscriptions,
        LiveSubscription(name: name, url: url),
      ];
      await storage.saveSubscriptions(items);
      if (mounted) state = state.copyWith(subscriptions: items);
    });
    await select(url);
  }

  Future<void> remove(String url) async {
    _tokens.remove(url)?.cancel('订阅已移除');
    _jobs.remove(url);
    await _mutate(() async {
      if (!mounted) return;
      final removed = state.subscriptions
          .where((s) => s.url == url)
          .firstOrNull;
      if (removed?.id case final String id) await storage.hideOfficial(id);
      final items = state.subscriptions.where((s) => s.url != url).toList();
      final selected = state.selectedUrl == url
          ? items.firstOrNull?.url
          : state.selectedUrl;
      state = state.copyWith(
        subscriptions: items,
        selectedUrl: selected,
        clearSelection: selected == null,
        playlists: {...state.playlists}..remove(url),
        errors: {...state.errors}..remove(url),
        loading: {...state.loading}..remove(url),
        hiddenOfficialCount: storage.hiddenOfficialIds.length,
      );
      await storage.saveSubscriptions(items);
      await storage.select(selected);
      await storage.removeCache(url);
    });
  }

  Future<void> refresh(String url) {
    if (!state.subscriptions.any((s) => s.url == url)) return Future.value();
    final existing = _jobs[url];
    if (existing != null) return existing;
    final completion = Completer<void>();
    // Register before executing, including synchronous repository failures.
    _jobs[url] = completion.future;
    unawaited(
      _refresh(
        url,
      ).then(completion.complete, onError: completion.completeError),
    );
    return completion.future;
  }

  Future<void> _refresh(String url) async {
    final token = CancelToken();
    _tokens[url] = token;
    state = state.copyWith(
      loading: {...state.loading, url},
      errors: {...state.errors}..remove(url),
    );
    bool current() =>
        mounted && identical(_tokens[url], token) && !token.isCancelled;
    try {
      final subscription = state.subscriptions.where((s) => s.url == url).first;
      final playlist = await repository.fetch(
        url,
        cancelToken: token,
        fallbackUrls: subscription.fallbackUrls,
      );
      if (!current()) return;
      await storage.cache(url, playlist);
      if (!current()) return;
      state = state.copyWith(playlists: {...state.playlists, url: playlist});
    } catch (error) {
      if (current()) {
        state = state.copyWith(
          errors: {...state.errors, url: sourceErrorMessage(error)},
        );
      }
    } finally {
      if (identical(_tokens[url], token)) {
        _tokens.remove(url);
        _jobs.remove(url);
        if (mounted) {
          state = state.copyWith(loading: {...state.loading}..remove(url));
        }
      }
      token.cancel('订阅请求已完成');
    }
  }

  @override
  void dispose() {
    _catalogTimer?.cancel();
    _catalogToken?.cancel('直播已关闭');
    for (final token in _tokens.values) {
      token.cancel('直播已关闭');
    }
    super.dispose();
  }
}
