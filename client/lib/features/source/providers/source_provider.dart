import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/local/source_storage.dart';
import '../../../data/models/site.dart';
import '../../../data/models/source_config.dart';
import '../../../data/models/warehouse.dart';
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

// ── 多仓解析 ──

/// 多仓解析结果：如果当前选中源是多仓，返回仓库列表；否则返回空列表
final warehouseListProvider = FutureProvider<List<Warehouse>>((ref) async {
  final url = ref.watch(selectedSourceUrlProvider);
  if (url == null || url.isEmpty) return [];
  if (SourceParser.isCmsApiUrl(url)) return [];
  if (SourceParser.isJarBridgeUrl(url)) return [];

  final parser = ref.read(sourceParserProvider);
  return await parser.parseMultiWarehouse(url) ?? [];
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

  // JAR Bridge URL → 通过 /api/list 发现插件
  if (SourceParser.isJarBridgeUrl(url)) {
    return parser.parseJarBridge(url);
  }

  // 直接 CMS API URL → 包装为单站点
  if (SourceParser.isCmsApiUrl(url)) {
    return SourceParser.wrapCmsUrl(url);
  }

  // 检查是否多仓
  final warehouses = await ref.watch(warehouseListProvider.future);
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
  return parser.parse(url);
});

/// 当前可用的站点列表（CMS 站点 + Bridge 站点）
final availableSitesProvider = Provider<List<Site>>((ref) {
  final configAsync = ref.watch(sourceConfigProvider);
  return configAsync.whenOrNull(data: (config) {
        if (config == null) return <Site>[];
        final bridgeSites = config.sites.where((s) => s.isBridge).toList();
        if (bridgeSites.isNotEmpty) return bridgeSites;
        return config.cmsSites;
      }) ??
      [];
});

/// 同步 availableSites 到 Home 模块的 sitesProvider
/// 在 source_manage_page 中调用
void syncSitesToHome(WidgetRef ref) {
  final sites = ref.read(availableSitesProvider);
  ref.read(sitesProvider.notifier).state = sites;
}
