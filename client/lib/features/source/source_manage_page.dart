import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/network/url_policy.dart';
import '../../data/local/source_storage.dart';
import '../../data/models/site.dart';
import '../../data/models/source_config.dart';
import '../../data/models/warehouse.dart';
import '../../data/sources/source_parser.dart';
import '../../widgets/tv_focus.dart';
import '../home/providers/categories_provider.dart';
import 'providers/source_provider.dart';
part 'source_manage_widgets.dart';

/// 配置源管理页面
/// [embedded] 为 true 时不渲染 Scaffold/AppBar，嵌入设置页使用
class SourceManagePage extends ConsumerStatefulWidget {
  final bool embedded;
  const SourceManagePage({super.key, this.embedded = false});

  @override
  ConsumerState<SourceManagePage> createState() => _SourceManagePageState();
}

class _SourceManagePageState extends ConsumerState<SourceManagePage> {
  bool _loading = false;
  String? _loadingUrl; // 正在加载的源 URL
  bool _builtInExpanded = true; // 内置片源是否展开（默认展开）

  /// 每个 tile 一个 FocusNode，按 URL 索引；新增源后用来 requestFocus 落点
  final Map<String, FocusNode> _tileFocusNodes = {};

  /// inline 状态条（替代 SnackBar，TV 视野内顶端浮层，4s 后自动淡出）
  String? _statusMessage;
  bool _statusError = false;
  Timer? _statusTimer;

  FocusNode _focusNodeFor(String url) {
    return _tileFocusNodes.putIfAbsent(
      url,
      () => FocusNode(debugLabel: 'source-tile-$url'),
    );
  }

  void _setStatus(String msg, {bool error = false}) {
    if (!mounted) return;
    _statusTimer?.cancel();
    setState(() {
      _statusMessage = msg;
      _statusError = error;
    });
    _statusTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _statusMessage = null);
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    for (final n in _tileFocusNodes.values) {
      n.dispose();
    }
    _tileFocusNodes.clear();
    super.dispose();
  }

  /// 调度下一帧把焦点 + 滚动落到 [url] 对应 tile。
  /// 调用时 ListView 通常还未把新 tile 渲染出来；postFrameCallback 等
  /// 重建完成 + FocusNode attach 完成后再 requestFocus。
  void _focusTileAfterFrame(String url) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _tileFocusNodes[url];
      if (node != null && node.canRequestFocus) {
        node.requestFocus();
        // TvFocusable 的 ensureVisibleOnFocus 会自动 scroll 到中间
      }
    });
  }

  Future<void> _openAddSourceDialog() async {
    final url = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const _AddSourceDialog(),
    );
    if (url == null || url.isEmpty) return;
    await _addSource(url);
  }

  Future<void> _addSource(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;

    try {
      if (SourceParser.isJarBridgeUrl(trimmed)) {
        UrlPolicy.requireGatewayUrl(trimmed);
      } else if (SourceParser.isCmsApiUrl(trimmed)) {
        UrlPolicy.requireCmsApiUrl(
          trimmed,
          allowLoopback: SourceParser.isJarBridgePluginUrl(trimmed),
        );
      } else {
        UrlPolicy.requireConfigUrl(trimmed);
      }
    } on FormatException catch (error) {
      _setStatus(error.message, error: true);
      return;
    }

    setState(() => _loading = true);

    bool added = false;
    try {
      // 保存 URL
      final urls = ref.read(savedSourceUrlsProvider);
      if (!urls.contains(trimmed)) {
        ref.read(savedSourceUrlsProvider.notifier).state = [...urls, trimmed];
      }
      added = true;

      // 存储到 Hive
      final storage = ref.read(sourceStorageProvider);
      await storage.add(trimmed);

      // 选中并加载
      ref.read(sitesProvider.notifier).state = [];
      ref.read(selectedSourceUrlProvider.notifier).state = trimmed;
      ref.read(selectedWarehouseUrlProvider.notifier).state = null;
      await storage.setSelected(trimmed);

      // 先解析最终配置；多仓在尚未选择仓库时返回 null。
      final config = await ref.read(sourceConfigProvider.future);
      if (config != null) {
        syncSitesToHome(ref);
        final isGateway = config.sites.any((site) => site.isGateway);
        _setStatus(isGateway ? 'Gateway 源加载成功' : '配置源加载成功');
      } else {
        final warehouses = await ref.read(warehouseListProvider.future);
        if (warehouses.isEmpty) {
          throw const FormatException('配置中没有可用站点或仓库');
        }
        _setStatus('多仓源已加载，共 ${warehouses.length} 个仓库，请选择');
      }
    } catch (e) {
      _setStatus('加载失败: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
      // URL 已加入 list（无论后续配置加载是否成功），把焦点落到新 tile
      if (added && mounted) _focusTileAfterFrame(trimmed);
    }
  }

  Future<void> _selectSource(String url) async {
    setState(() => _loadingUrl = url);

    // 新源尚未完成解析前进入明确空状态，绝不继续展示或查询旧源。
    ref.read(sitesProvider.notifier).state = [];
    ref.read(selectedSourceUrlProvider.notifier).state = url;
    // 切换源时先清空仓库选择
    ref.read(selectedWarehouseUrlProvider.notifier).state = null;

    final storage = ref.read(sourceStorageProvider);
    await storage.setSelected(url);

    try {
      final config = await ref.read(sourceConfigProvider.future);
      if (config != null) {
        syncSitesToHome(ref);
      } else {
        final warehouses = await ref.read(warehouseListProvider.future);
        // 恢复上次选中的仓库
        final lastWh = storage.getSelectedWarehouse(url);
        if (lastWh != null && warehouses.any((w) => w.url == lastWh)) {
          await _selectWarehouse(lastWh, persist: false);
        } else if (warehouses.isNotEmpty) {
          _setStatus('请选择一个仓库');
        } else {
          throw const FormatException('配置中没有可用站点或仓库');
        }
      }
    } catch (error) {
      _setStatus('片源加载失败: $error', error: true);
    } finally {
      if (mounted) setState(() => _loadingUrl = null);
    }
  }

  Future<void> _selectWarehouse(
    String warehouseUrl, {
    bool persist = true,
  }) async {
    setState(() => _loadingUrl = warehouseUrl);

    ref.read(sitesProvider.notifier).state = [];
    ref.read(selectedWarehouseUrlProvider.notifier).state = warehouseUrl;

    if (persist) {
      final sourceUrl = ref.read(selectedSourceUrlProvider);
      if (sourceUrl != null) {
        final storage = ref.read(sourceStorageProvider);
        await storage.setSelectedWarehouse(sourceUrl, warehouseUrl);
      }
    }

    try {
      await ref.read(sourceConfigProvider.future);
      syncSitesToHome(ref);
    } catch (error) {
      _setStatus('仓库加载失败: $error', error: true);
    } finally {
      if (mounted) setState(() => _loadingUrl = null);
    }
  }

  void _removeSource(String url) async {
    final urls = ref.read(savedSourceUrlsProvider);
    ref.read(savedSourceUrlsProvider.notifier).state = urls
        .where((u) => u != url)
        .toList();

    final storage = ref.read(sourceStorageProvider);
    await storage.remove(url);

    // 释放该 tile 的 FocusNode（避免 widget 卸载后 leak）
    _tileFocusNodes.remove(url)?.dispose();

    // 如果删除的是当前选中的，清空
    if (ref.read(selectedSourceUrlProvider) == url) {
      ref.read(selectedSourceUrlProvider.notifier).state = null;
      ref.read(selectedWarehouseUrlProvider.notifier).state = null;
      ref.read(sitesProvider.notifier).state = [];
    }
  }

  Widget _buildTile(
    String url,
    String? selectedUrl,
    AsyncValue<List<Warehouse>> warehousesAsync,
  ) {
    final isSelected = url == selectedUrl;
    final isMultiWarehouse =
        isSelected &&
        warehousesAsync.hasValue &&
        !warehousesAsync.isLoading &&
        warehousesAsync.value!.isNotEmpty;
    return _SourceTile(
      url: url,
      focusNode: _focusNodeFor(url),
      isSelected: isSelected,
      isLoading: _loadingUrl == url,
      isMultiWarehouse: isMultiWarehouse,
      onTap: () => _selectSource(url),
      onDelete: SourceStorage.isBuiltIn(url) ? null : () => _removeSource(url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final savedUrls = ref.watch(savedSourceUrlsProvider);
    final selectedUrl = ref.watch(selectedSourceUrlProvider);
    final configAsync = ref.watch(sourceConfigProvider);
    final warehousesAsync = ref.watch(warehouseListProvider);

    final builtIn = savedUrls.where((u) => SourceStorage.isBuiltIn(u)).toList();
    final thirdParty = savedUrls
        .where((u) => !SourceStorage.isBuiltIn(u))
        .toList();

    final addInput = _AddSourceTrigger(
      loading: _loading,
      onActivate: _loading ? null : _openAddSourceDialog,
    );

    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: savedUrls.isEmpty
                ? Center(child: Text('暂无配置源', style: AppTypography.body))
                : ListView(
                    children: [
                      // 1. 内置片源（最上，默认展开，可折叠）
                      if (builtIn.isNotEmpty) ...[
                        _ExpandToggleRow(
                          expanded: _builtInExpanded,
                          count: builtIn.length,
                          onToggle: () => setState(
                            () => _builtInExpanded = !_builtInExpanded,
                          ),
                        ),
                        if (_builtInExpanded) ...[
                          const SizedBox(height: AppSpacing.sm),
                          ...builtIn.map(
                            (url) => Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.sm,
                              ),
                              child: _buildTile(
                                url,
                                selectedUrl,
                                warehousesAsync,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),
                        const Divider(color: AppColors.divider),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      // 2. 添加配置源
                      addInput,
                      // 3. 第三方片源
                      if (thirdParty.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.lg),
                        const Divider(color: AppColors.divider),
                        const SizedBox(height: AppSpacing.lg),
                        Text('第三方片源', style: AppTypography.headline2),
                        const SizedBox(height: AppSpacing.sm),
                        ...thirdParty.map(
                          (url) => Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.sm,
                            ),
                            child: _buildTile(
                              url,
                              selectedUrl,
                              warehousesAsync,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          // 仓库选择器（多仓模式，加载中时隐藏避免显示旧数据）
          if (warehousesAsync.hasValue &&
              !warehousesAsync.isLoading &&
              warehousesAsync.value!.isNotEmpty) ...[
            const Divider(color: AppColors.divider),
            const SizedBox(height: AppSpacing.sm),
            _WarehousePicker(
              warehouses: warehousesAsync.value!,
              selectedUrl: ref.watch(selectedWarehouseUrlProvider),
              loadingUrl: _loadingUrl,
              onSelect: _selectWarehouse,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          // Bridge 插件选择器（仅当前选中 Bridge 源时显示）
          if (selectedUrl != null &&
              selectedUrl.contains(':9978') &&
              configAsync.hasValue &&
              configAsync.value != null &&
              configAsync.value!.sites.any((s) => s.isBridge)) ...[
            const Divider(color: AppColors.divider),
            const SizedBox(height: AppSpacing.sm),
            _BridgePluginPicker(
              // ValueKey 让同一 sourceUrl 的 State 复用，切换源时重建
              key: ValueKey('bridge-$selectedUrl'),
              sourceUrl: selectedUrl,
              plugins: configAsync.value!.sites
                  .where((s) => s.isBridge)
                  .toList(),
              onSelect: (sites) {
                ref.read(sitesProvider.notifier).state = sites;
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          // 当前配置源详情
          if (configAsync.hasValue && configAsync.value != null) ...[
            const Divider(color: AppColors.divider),
            const SizedBox(height: AppSpacing.sm),
            _SourceConfigInfo(config: configAsync.value!),
          ],
        ],
      ),
    );

    final body = Stack(
      children: [
        Positioned.fill(child: content),
        if (_statusMessage != null)
          Positioned(
            top: AppSpacing.md,
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            child: _StatusBanner(text: _statusMessage!, error: _statusError),
          ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('配置源管理')),
      body: body,
    );
  }
}

/// inline 状态条：替代 SnackBar 的 TV 友好版本（顶端浮层，不依赖底部
/// ScaffoldMessenger 视野）。错误用 warning 色，正常用 success 色。
