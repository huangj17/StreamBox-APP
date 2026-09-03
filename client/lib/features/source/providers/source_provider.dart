import 'dart:async';
import 'dart:collection';

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
import 'source_library_provider.dart';

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
        cmsOnly: true,
      );
      ref.listen<List<String>>(sourceHealthUrlsProvider, (_, urls) {
        notifier.setSources(urls);
      }, fireImmediately: true);
      return notifier;
    });

final sourceHealthUrlsProvider = Provider<List<String>>((ref) {
  final library = ref.watch(sourceLibraryProvider);
  return library.allSites
      .where((s) => s.isSupported)
      .map((s) => s.api)
      .toSet()
      .toList();
});

class SourceHealthNotifier extends StateNotifier<Map<String, SourceHealth>> {
  static const refreshInterval = Duration(minutes: 15);
  static const startupDelay = Duration(seconds: 2);

  final SourceHealthChecker _checker;
  final bool cmsOnly;
  final int maxConcurrentChecks;
  final Duration checkTimeout;
  Timer? _startupTimer;
  Timer? _periodicTimer;
  List<String> _sources = const [];
  final _pending = Queue<_HealthCheckJob>();
  final _jobs = <String, _HealthCheckJob>{};
  int _running = 0;
  bool _disposed = false;

  SourceHealthNotifier(
    this._checker, {
    this.cmsOnly = false,
    this.maxConcurrentChecks = 6,
    this.checkTimeout = const Duration(seconds: 12),
  }) : assert(maxConcurrentChecks > 0),
       assert(checkTimeout > Duration.zero),
       super(const {});

  void setSources(List<String> urls) {
    if (_disposed) return;
    final unique = urls.toSet();
    final previousSources = _sources.toSet();
    _sources = unique.toList(growable: false);
    for (final job in _jobs.values.toList()) {
      if (unique.contains(job.url)) continue;
      _jobs.remove(job.url);
      _pending.remove(job);
      job.cancel('片源已移除');
    }
    state = {
      for (final url in unique) url: state[url] ?? const SourceHealth.queued(),
    };

    if (unique.isEmpty) {
      _startupTimer?.cancel();
      _startupTimer = null;
      _periodicTimer?.cancel();
      _periodicTimer = null;
      return;
    }
    _periodicTimer ??= Timer.periodic(refreshInterval, (_) {
      unawaited(refreshAll());
    });

    if (previousSources.isEmpty) {
      _startupTimer?.cancel();
      _startupTimer = Timer(startupDelay, () => unawaited(refreshAll()));
    } else if (!(_startupTimer?.isActive ?? false)) {
      unawaited(_refresh(unique.difference(previousSources).toList()));
    }
  }

  Future<void> refreshAll() {
    _startupTimer?.cancel();
    _startupTimer = null;
    return _refresh(_sources);
  }

  Future<void> refreshUrls(List<String> urls) => _refresh(urls);

  /// 前台恢复仅检测过期项，已排队或正在检测的项目共享原任务。
  Future<void> refreshStale({Duration maxAge = refreshInterval}) {
    final cutoff = DateTime.now().subtract(maxAge);
    return _refresh(
      _sources.where((url) {
        final health = state[url];
        if (health?.isPending ?? false) return false;
        final checkedAt = health?.checkedAt;
        return checkedAt == null || checkedAt.isBefore(cutoff);
      }).toList(),
    );
  }

  Future<void> _refresh(List<String> requested) async {
    if (_disposed || requested.isEmpty) return;
    final waiting = <Future<void>>[];
    final nextState = {...state};
    for (final url in requested.toSet()) {
      if (!_sources.contains(url)) continue;
      var job = _jobs[url];
      if (job == null) {
        job = _HealthCheckJob(url);
        _jobs[url] = job;
        _pending.add(job);
        nextState[url] = const SourceHealth.queued();
      }
      waiting.add(job.done.future);
    }
    state = nextState;
    _pump();
    await Future.wait(waiting);
  }

  /// 每空出一个位置就立即补一个任务，不等待同批最慢的片源。
  void _pump() {
    while (!_disposed &&
        _running < maxConcurrentChecks &&
        _pending.isNotEmpty) {
      final job = _pending.removeFirst();
      if (!_isCurrent(job)) continue;
      _running++;
      unawaited(_checkOne(job));
    }
  }

  bool _isCurrent(_HealthCheckJob job) =>
      !_disposed && identical(_jobs[job.url], job);

  Future<void> _checkOne(_HealthCheckJob job) async {
    try {
      state = {...state, job.url: const SourceHealth.checking()};
      final result =
          await Future.any<SourceHealth>([
            Future.sync(
              () => cmsOnly
                  ? _checker.checkCms(job.url, cancelToken: job.token)
                  : _checker.check(job.url, cancelToken: job.token),
            ),
            job.token.whenCancel.then<SourceHealth>((error) => throw error),
          ]).timeout(
            checkTimeout,
            onTimeout: () {
              // Cancel the HTTP/stream work as well as releasing the worker slot.
              job.token.cancel('片源检测超时');
              return SourceHealth.unavailable(
                message: '检测超时（${checkTimeout.inSeconds} 秒），可重新检测',
              );
            },
          );
      if (_isCurrent(job)) state = {...state, job.url: result};
    } catch (_) {
      if (_isCurrent(job)) {
        state = {
          ...state,
          job.url: SourceHealth.unavailable(message: '检测失败，可重试'),
        };
      }
    } finally {
      if (_isCurrent(job)) _jobs.remove(job.url);
      job.cancel('检测结束');
      _running--;
      _pump();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    for (final job in _jobs.values) {
      job.cancel('检测器已关闭');
    }
    _jobs.clear();
    _pending.clear();
    super.dispose();
  }
}

class _HealthCheckJob {
  final String url;
  final token = CancelToken();
  final done = Completer<void>();
  _HealthCheckJob(this.url);

  void cancel(String reason) {
    token.cancel(reason);
    if (!done.isCompleted) done.complete();
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
