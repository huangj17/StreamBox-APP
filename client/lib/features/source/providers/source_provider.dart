import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/local/source_storage.dart';
import '../../../data/models/site.dart';
import '../../../data/models/source_config.dart';
import '../../../data/models/source_health.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/sources/source_health_checker.dart';
import '../../../data/sources/source_parser.dart';
import '../../home/providers/categories_provider.dart';

// ── 基础设施 ──

/// 通过 main.dart 的 ProviderScope.overrides 注入已初始化实例
final sourceStorageProvider = Provider<SourceStorage>(
  (ref) => throw UnimplementedError('sourceStorageProvider must be overridden'),
);

final sourceParserProvider = Provider<SourceParser>((ref) {
  return SourceParser(ref.watch(dioProvider));
});

// ── 配置源列表 ──

/// 已保存的配置源 URL 列表
final savedSourceUrlsProvider = StateProvider<List<String>>((ref) => []);

/// 当前选中的配置源 URL
final selectedSourceUrlProvider = StateProvider<String?>((ref) => null);

/// 当前选中的仓库 URL（多仓模式下使用）
final selectedWarehouseUrlProvider = StateProvider<String?>((ref) => null);

// ── 片源健康检测 ──

final sourceHealthCheckerProvider = Provider<SourceHealthChecker>((ref) {
  return SourceHealthChecker(ref.watch(dioProvider));
});

/// 配置源 URL → 最近一次健康状态。
///
/// 首次恢复片源后延迟 2 秒后台检测，避免与首屏请求抢网络；
/// 之后每 15 分钟重新检测。
final sourceHealthProvider =
    StateNotifierProvider<SourceHealthNotifier, Map<String, SourceHealth>>((
      ref,
    ) {
      final notifier = SourceHealthNotifier(
        ref.watch(sourceHealthCheckerProvider),
      );
      ref.listen<List<String>>(savedSourceUrlsProvider, (_, urls) {
        notifier.setSources(urls);
      }, fireImmediately: true);
      return notifier;
    });

class SourceHealthNotifier extends StateNotifier<Map<String, SourceHealth>> {
  static const refreshInterval = Duration(minutes: 15);
  static const startupDelay = Duration(seconds: 2);
  static const _concurrency = 3;

  final SourceHealthChecker _checker;
  Timer? _startupTimer;
  Timer? _periodicTimer;
  List<String> _sources = const [];
  bool _refreshing = false;
  bool _refreshQueued = false;
  bool _disposed = false;

  SourceHealthNotifier(this._checker) : super(const {});

  void setSources(List<String> urls) {
    if (_disposed) return;
    final unique = urls.toSet().toList(growable: false);
    final previousSources = _sources.toSet();
    _sources = unique;
    state = {
      for (final url in unique)
        url: state[url] ?? const SourceHealth.checking(),
    };

    if (unique.isEmpty) {
      _startupTimer?.cancel();
      _periodicTimer?.cancel();
      _periodicTimer = null;
      return;
    }

    _periodicTimer ??= Timer.periodic(refreshInterval, (_) {
      unawaited(refreshAll());
    });

    final added = unique
        .where((url) => !previousSources.contains(url))
        .toList();
    if (previousSources.isEmpty) {
      _startupTimer?.cancel();
      _startupTimer = Timer(startupDelay, () => unawaited(refreshAll()));
    } else if (added.isNotEmpty) {
      unawaited(_refresh(added));
    }
  }

  Future<void> refreshAll() => _refresh(_sources);

  /// 仅刷新超过 [maxAge] 未检测的片源。
  ///
  /// macOS 窗口每次重新获得焦点都会触发 resumed；这里避免普通切窗绕过
  /// 15 分钟周期，仍能在应用长时间处于后台后及时补一次检测。
  Future<void> refreshStale({Duration maxAge = refreshInterval}) {
    final cutoff = DateTime.now().subtract(maxAge);
    final stale = _sources
        .where((url) {
          final health = state[url];
          if (health?.status == SourceHealthStatus.checking) return false;
          final checkedAt = health?.checkedAt;
          return checkedAt == null || checkedAt.isBefore(cutoff);
        })
        .toList(growable: false);
    return _refresh(stale);
  }

  Future<void> _refresh(List<String> requested) async {
    if (_disposed || requested.isEmpty) return;
    if (_refreshing) {
      _refreshQueued = true;
      return;
    }
    _refreshing = true;
    try {
      final current = _sources.toSet();
      final targets = requested.where(current.contains).toList(growable: false);
      for (var offset = 0; offset < targets.length; offset += _concurrency) {
        if (_disposed) return;
        final end = offset + _concurrency < targets.length
            ? offset + _concurrency
            : targets.length;
        final batch = targets.sublist(offset, end);
        await Future.wait(batch.map(_checkOne));
      }
    } finally {
      _refreshing = false;
      if (_refreshQueued && !_disposed) {
        _refreshQueued = false;
        unawaited(refreshAll());
      }
    }
  }

  Future<void> _checkOne(String url) async {
    if (!_sources.contains(url) || _disposed) return;
    state = {...state, url: const SourceHealth.checking()};
    final result = await _checker.check(url);
    if (!_sources.contains(url) || _disposed) return;
    state = {...state, url: result};
  }

  @override
  void dispose() {
    _disposed = true;
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    super.dispose();
  }
}

// ── 多仓解析 ──

/// 当前普通配置 URL 的单次解析结果。仓库列表和单仓配置共享这个 Future，
/// 避免先判多仓、再解析单仓时把同一文档下载两次。
final sourceDocumentProvider = FutureProvider<ParsedSourceDocument?>((
  ref,
) async {
  final url = ref.watch(selectedSourceUrlProvider);
  if (url == null || url.isEmpty) return null;
  if (SourceParser.isCmsApiUrl(url) || SourceParser.isJarBridgeUrl(url)) {
    return null;
  }
  return ref.read(sourceParserProvider).parseDocument(url);
});

/// 多仓解析结果：如果当前选中源是多仓，返回仓库列表；否则返回空列表
final warehouseListProvider = FutureProvider<List<Warehouse>>((ref) async {
  final url = ref.watch(selectedSourceUrlProvider);
  if (url == null || url.isEmpty) return [];
  if (SourceParser.isCmsApiUrl(url)) return [];
  if (SourceParser.isJarBridgeUrl(url)) return [];

  final document = await ref.watch(sourceDocumentProvider.future);
  return document?.warehouses ?? [];
});

// ── 配置源解析 ──

/// 本地 Bridge 自动覆盖：远程 Bridge URL 在本地 Bridge 起着时（500ms 内 /health
/// 200）改用 `http://localhost:9978`。开发/调试无需手动改源 URL。
///
/// 不污染 storage（用户保存的远程 URL 保留），仅 runtime 切换。
Future<String> _preferLocalBridge(String url, Dio dio) async {
  if (!url.contains(':9978')) return url; // 非 Bridge
  if (url.contains('localhost') || url.contains('127.0.0.1')) return url;
  try {
    final r = await dio.get<dynamic>(
      'http://localhost:9978/health',
      options: Options(
        receiveTimeout: const Duration(milliseconds: 500),
        sendTimeout: const Duration(milliseconds: 500),
      ),
    );
    if (r.statusCode == 200) return 'http://localhost:9978';
  } catch (_) {
    // 本地没起，回退原远程
  }
  return url;
}

/// 当前选中配置源的解析结果
/// 支持四种情况：JAR Bridge URL、直接 CMS API URL、单仓 JSON、多仓 JSON
final sourceConfigProvider = FutureProvider<SourceConfig?>((ref) async {
  final raw = ref.watch(selectedSourceUrlProvider);
  if (raw == null || raw.isEmpty) return null;

  final parser = ref.read(sourceParserProvider);

  // 远程 Bridge → 优先用本地 Bridge（如果起着）
  final url = SourceParser.isJarBridgeUrl(raw)
      ? await _preferLocalBridge(raw, ref.read(dioProvider))
      : raw;

  // 直接 CMS API URL → 包装为单站点
  if (SourceParser.isCmsApiUrl(url)) {
    return SourceParser.wrapCmsUrl(url);
  }

  // 明确 Bridge 或无路径 HTTPS 根地址才探测 Gateway Schema。普通配置文件
  // 路径直接解析，避免无意义的 /api/list 请求。
  if (SourceParser.shouldProbeGateway(url)) {
    final gateway = await parser.probeGateway(url);
    if (gateway != null) return gateway;
  }

  // 单仓/多仓共享同一份已下载文档。
  final document = await ref.watch(sourceDocumentProvider.future);
  final warehouses = document?.warehouses ?? [];
  if (warehouses.isNotEmpty) {
    // 多仓：等待用户选择仓库
    final whUrl = ref.watch(selectedWarehouseUrlProvider);
    if (whUrl == null || whUrl.isEmpty) return null;

    // 仓库 URL 可能本身就是 CMS API
    if (SourceParser.isCmsApiUrl(whUrl)) {
      return SourceParser.wrapCmsUrl(whUrl);
    }
    return parser.parse(whUrl);
  }

  // 单仓：直接解析
  return document?.config;
});

/// 当前可用的站点列表（CMS 站点 + Bridge 站点）
final availableSitesProvider = Provider<List<Site>>((ref) {
  final configAsync = ref.watch(sourceConfigProvider);
  return configAsync.whenOrNull(
        data: (config) {
          if (config == null) return <Site>[];
          final cmsSites = config.cmsSites.toSet();
          return config.sites
              .where((site) => site.isBridge || cmsSites.contains(site))
              .toList();
        },
      ) ??
      [];
});

/// 同步 availableSites 到 Home 模块的 sitesProvider
/// 在 source_manage_page 中调用
void syncSitesToHome(WidgetRef ref) {
  final sites = ref.read(availableSitesProvider);
  ref.read(sitesProvider.notifier).state = sites;
}
