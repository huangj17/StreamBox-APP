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
        UrlPolicy.requireCmsApiUrl(trimmed);
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
        ref.read(savedSourceUrlsProvider.notifier).state = [
          ...urls,
          trimmed,
        ];
      }
      added = true;

      // 存储到 Hive
      final storage = ref.read(sourceStorageProvider);
      await storage.add(trimmed);

      // 选中并加载
      ref.read(selectedSourceUrlProvider.notifier).state = trimmed;
      await storage.setSelected(trimmed);

      // JAR Bridge URL：直接加载
      if (trimmed.contains(':9978')) {
        await ref.read(sourceConfigProvider.future);
        syncSitesToHome(ref);
        _setStatus('Bridge 源加载成功');
        setState(() => _loading = false);
        return;
      }

      // 等待多仓检测
      final warehouses = await ref.read(warehouseListProvider.future);

      if (warehouses.isNotEmpty) {
        // 多仓：提示用户选择仓库
        _setStatus('多仓源已加载，共 ${warehouses.length} 个仓库，请选择');
      } else {
        // 单仓：直接加载
        await ref.read(sourceConfigProvider.future);
        syncSitesToHome(ref);
        _setStatus('配置源加载成功');
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

    ref.read(selectedSourceUrlProvider.notifier).state = url;
    // 切换源时先清空仓库选择
    ref.read(selectedWarehouseUrlProvider.notifier).state = null;

    final storage = ref.read(sourceStorageProvider);
    await storage.setSelected(url);

    try {
      // 检测是否多仓
      final warehouses = await ref.read(warehouseListProvider.future);
      if (warehouses.isNotEmpty) {
        // 恢复上次选中的仓库
        final lastWh = storage.getSelectedWarehouse(url);
        if (lastWh != null &&
            warehouses.any((w) => w.url == lastWh)) {
          await _selectWarehouse(lastWh, persist: false);
        }
      } else {
        // 单仓：直接加载
        await ref.read(sourceConfigProvider.future);
        syncSitesToHome(ref);
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _loadingUrl = null);
    }
  }

  Future<void> _selectWarehouse(String warehouseUrl,
      {bool persist = true}) async {
    setState(() => _loadingUrl = warehouseUrl);

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
    } catch (_) {} finally {
      if (mounted) setState(() => _loadingUrl = null);
    }
  }

  void _removeSource(String url) async {
    final urls = ref.read(savedSourceUrlsProvider);
    ref.read(savedSourceUrlsProvider.notifier).state =
        urls.where((u) => u != url).toList();

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
    final isMultiWarehouse = isSelected &&
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
      onDelete:
          SourceStorage.isBuiltIn(url) ? null : () => _removeSource(url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final savedUrls = ref.watch(savedSourceUrlsProvider);
    final selectedUrl = ref.watch(selectedSourceUrlProvider);
    final configAsync = ref.watch(sourceConfigProvider);
    final warehousesAsync = ref.watch(warehouseListProvider);

    final builtIn =
        savedUrls.where((u) => SourceStorage.isBuiltIn(u)).toList();
    final thirdParty =
        savedUrls.where((u) => !SourceStorage.isBuiltIn(u)).toList();

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
                              () => _builtInExpanded = !_builtInExpanded),
                        ),
                        if (_builtInExpanded) ...[
                          const SizedBox(height: AppSpacing.sm),
                          ...builtIn.map((url) => Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppSpacing.sm),
                                child: _buildTile(
                                    url, selectedUrl, warehousesAsync),
                              )),
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
                        ...thirdParty.map((url) => Padding(
                              padding:
                                  const EdgeInsets.only(bottom: AppSpacing.sm),
                              child:
                                  _buildTile(url, selectedUrl, warehousesAsync),
                            )),
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
              plugins:
                  configAsync.value!.sites.where((s) => s.isBridge).toList(),
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
            child: _StatusBanner(
              text: _statusMessage!,
              error: _statusError,
            ),
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
class _StatusBanner extends StatelessWidget {
  final String text;
  final bool error;

  const _StatusBanner({required this.text, required this.error});

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.warning : AppColors.success;
    return IgnorePointer(
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withAlpha(160), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                color: color,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  text,
                  style: AppTypography.body.copyWith(
                    color: AppColors.primaryText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 仓库选择器 ──

class _WarehousePicker extends StatelessWidget {
  final List<Warehouse> warehouses;
  final String? selectedUrl;
  final String? loadingUrl;
  final void Function(String url) onSelect;

  const _WarehousePicker({
    required this.warehouses,
    required this.selectedUrl,
    this.loadingUrl,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('选择仓库', style: AppTypography.headline2),
            const SizedBox(width: AppSpacing.sm),
            _InfoChip('${warehouses.length} 个', AppColors.info),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: warehouses.length,
            separatorBuilder: (_, _) =>
                const SizedBox(width: AppSpacing.sm),
            itemBuilder: (ctx, index) {
              final wh = warehouses[index];
              final isSelected = wh.url == selectedUrl;
              final isLoading = wh.url == loadingUrl;
              return _WarehouseChip(
                name: wh.name.isNotEmpty ? wh.name : '仓库 ${index + 1}',
                isSelected: isSelected,
                isLoading: isLoading,
                onTap: () => onSelect(wh.url),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _WarehouseChip extends StatelessWidget {
  final String name;
  final bool isSelected;
  final bool isLoading;
  final VoidCallback onTap;

  const _WarehouseChip({
    required this.name,
    required this.isSelected,
    this.isLoading = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'warehouse-chip-$name',
      onActivate: onTap,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.netflixRed.withAlpha(30)
                : AppColors.cardBackground,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: isSelected || focused
                  ? AppColors.netflixRed
                  : AppColors.divider,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: isSelected
                        ? AppColors.netflixRed
                        : AppColors.primaryText,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                name,
                style: AppTypography.caption.copyWith(
                  color: isSelected
                      ? AppColors.netflixRed
                      : AppColors.primaryText,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 可聚焦的「内置片源」折叠行：标题 + 计数 + 展开箭头
class _ExpandToggleRow extends StatelessWidget {
  final bool expanded;
  final int count;
  final VoidCallback onToggle;

  const _ExpandToggleRow({
    required this.expanded,
    required this.count,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'expand-toggle-row',
      onActivate: onToggle,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: focused ? AppColors.netflixRed : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('内置片源', style: AppTypography.headline2),
              const SizedBox(width: AppSpacing.xs),
              _InfoChip('$count 个', AppColors.hintText),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                expanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                color:
                    focused ? AppColors.netflixRed : AppColors.hintText,
                size: 20,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── 源列表 Tile ──

/// 选中/焦点视觉分离：
/// - selected → 红 ✓ + 红粗标题（无外边框）
/// - focused  → 红边框 + 红光晕
/// - 第三方源支持「长按 OK 删除」（≥500ms），短按/Enter 仍是切换选中
class _SourceTile extends StatelessWidget {
  final String url;
  final FocusNode? focusNode;
  final bool isSelected;
  final bool isLoading;
  final bool isMultiWarehouse;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _SourceTile({
    required this.url,
    required this.isSelected,
    required this.isLoading,
    required this.isMultiWarehouse,
    required this.onTap,
    this.focusNode,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final name = SourceStorage.nameOf(url);
    final desc = SourceStorage.descOf(url);

    return TvFocusable(
      debugLabel: 'source-tile-$url',
      focusNode: focusNode,
      onActivate: onTap,
      onLongActivate: onDelete,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.surface
                : AppColors.cardBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused ? AppColors.netflixRed : Colors.transparent,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: _SourceTileInner(
            name: name,
            desc: desc,
            isSelected: isSelected,
            isLoading: isLoading,
            isMultiWarehouse: isMultiWarehouse,
            focused: focused,
            canDelete: onDelete != null,
            onDelete: onDelete,
          ),
        );
      },
    );
  }
}

/// 仅渲染内容，不处理点击/焦点（外层 [TvFocusable] 已统一）
class _SourceTileInner extends StatelessWidget {
  final String name;
  final String? desc;
  final bool isSelected;
  final bool isLoading;
  final bool isMultiWarehouse;
  final bool focused;
  final bool canDelete;
  final VoidCallback? onDelete;

  const _SourceTileInner({
    required this.name,
    required this.desc,
    required this.isSelected,
    required this.isLoading,
    required this.isMultiWarehouse,
    required this.focused,
    required this.canDelete,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: isLoading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.netflixRed,
              ),
            )
          : Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              color: isSelected ? AppColors.netflixRed : AppColors.hintText,
            ),
      title: Row(
        children: [
          Text(
            name,
            style: AppTypography.body.copyWith(
              color: isSelected
                  ? AppColors.netflixRed
                  : AppColors.primaryText,
              fontWeight:
                  isSelected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          if (isMultiWarehouse) ...[
            const SizedBox(width: AppSpacing.sm),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.info.withAlpha(30),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '多仓',
                style: AppTypography.caption.copyWith(
                  color: AppColors.info,
                  fontSize: 10,
                ),
              ),
            ),
          ],
          if (desc != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(
              desc!,
              style: AppTypography.caption.copyWith(
                color: AppColors.secondaryText,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
      subtitle: canDelete && focused
          ? Text(
              '长按 OK 删除',
              style: AppTypography.caption.copyWith(
                color: AppColors.hintText,
                fontSize: 11,
              ),
            )
          : null,
      // 鼠标用户保留删除图标；TV 用户走长按 OK，IconButton 不参与焦点流
      trailing: canDelete
          ? ExcludeFocus(
              child: IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.hintText),
                onPressed: onDelete,
              ),
            )
          : null,
    );
  }
}

// ── 配置源信息 ──

class _SourceConfigInfo extends StatelessWidget {
  final SourceConfig config;

  const _SourceConfigInfo({required this.config});

  @override
  Widget build(BuildContext context) {
    final cmsSites = config.cmsSites;
    final jarSites = config.sites.length - cmsSites.length;

    return Row(
      children: [
        _InfoChip('可用站点: ${cmsSites.length}', AppColors.success),
        const SizedBox(width: AppSpacing.sm),
        if (jarSites > 0)
          _InfoChip('JAR 站点: $jarSites (暂不支持)', AppColors.warning),
        const SizedBox(width: AppSpacing.sm),
        if (config.lives.isNotEmpty)
          _InfoChip('直播源: ${config.lives.length}', AppColors.info),
      ],
    );
  }
}

// ── Bridge 插件选择器 ──

class _BridgePluginPicker extends ConsumerStatefulWidget {
  final String sourceUrl;
  final List<Site> plugins;
  final void Function(List<Site> selectedSites) onSelect;

  const _BridgePluginPicker({
    super.key,
    required this.sourceUrl,
    required this.plugins,
    required this.onSelect,
  });

  @override
  ConsumerState<_BridgePluginPicker> createState() =>
      _BridgePluginPickerState();
}

class _BridgePluginPickerState extends ConsumerState<_BridgePluginPicker> {
  String? _selectedKey; // null = 全部

  @override
  void initState() {
    super.initState();
    // 恢复上次选中的插件并同步到 sitesProvider；
    // 若 storage 中 key 已不在当前 plugins 列表里（插件下线），视为"全部"
    final storage = ref.read(sourceStorageProvider);
    final lastKey = storage.getSelectedBridgePlugin(widget.sourceUrl);
    if (lastKey != null && widget.plugins.any((p) => p.key == lastKey)) {
      _selectedKey = lastKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final plugin = widget.plugins.firstWhere((p) => p.key == lastKey);
        widget.onSelect([plugin]);
      });
    }
  }

  Future<void> _select(String? key) async {
    setState(() => _selectedKey = key);
    final storage = ref.read(sourceStorageProvider);
    await storage.setSelectedBridgePlugin(widget.sourceUrl, key);
    if (key == null) {
      widget.onSelect(widget.plugins);
    } else {
      final plugin = widget.plugins.firstWhere((p) => p.key == key);
      widget.onSelect([plugin]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: widget.plugins.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (ctx, index) {
          if (index == 0) {
            final isSelected = _selectedKey == null;
            return _BridgeChip(
              name: '全部',
              isSelected: isSelected,
              onTap: () => _select(null),
            );
          }
          final plugin = widget.plugins[index - 1];
          final isSelected = plugin.key == _selectedKey;
          return _BridgeChip(
            name: plugin.name,
            isSelected: isSelected,
            onTap: () => _select(plugin.key),
          );
        },
      ),
    );
  }
}

class _BridgeChip extends StatelessWidget {
  final String name;
  final bool isSelected;
  final VoidCallback onTap;

  const _BridgeChip({
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'bridge-chip-$name',
      onActivate: onTap,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.netflixRed
                : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected || focused
                  ? AppColors.netflixRed
                  : AppColors.divider,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            name,
            style: AppTypography.caption.copyWith(
              color: isSelected ? Colors.white : AppColors.primaryText,
              fontWeight:
                  isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        );
      },
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final Color color;

  const _InfoChip(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(color: color),
      ),
    );
  }
}

// ── 添加配置源：列表中的触发按钮 + 弹窗 ──

/// 列表中显示的「+ 添加配置源」按钮。OK 弹 [_AddSourceDialog]。
/// TV 焦点流不再被 TextField 卡住。
class _AddSourceTrigger extends StatelessWidget {
  final bool loading;
  final VoidCallback? onActivate;

  const _AddSourceTrigger({required this.loading, required this.onActivate});

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'add-source-trigger',
      onActivate: onActivate,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.cardBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused
                  ? AppColors.netflixRed
                  : AppColors.divider,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              if (loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.netflixRed,
                  ),
                )
              else
                Icon(
                  Icons.add_circle_outline,
                  size: 20,
                  color:
                      focused ? AppColors.netflixRed : AppColors.primaryText,
                ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loading ? '加载中...' : '添加配置源',
                      style: AppTypography.body.copyWith(
                        color: focused
                            ? AppColors.netflixRed
                            : AppColors.primaryText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '支持苹果 CMS API、TVBox 单仓/多仓配置源 URL',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.hintText,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: focused
                    ? AppColors.netflixRed
                    : AppColors.hintText,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 添加配置源弹窗：含 TextField + 确定/取消，Esc/Back 关闭。
/// 返回值：用户输入的 URL（已 trim），取消则为 null。
class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog();

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _controller = TextEditingController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'add-source-input');
  final FocusNode _cancelFocus = FocusNode(debugLabel: 'add-source-cancel');
  final FocusNode _confirmFocus = FocusNode(debugLabel: 'add-source-confirm');
  bool _inputFocused = false;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(_onInputFocus);
  }

  @override
  void dispose() {
    _inputFocus.removeListener(_onInputFocus);
    _inputFocus.dispose();
    _cancelFocus.dispose();
    _confirmFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onInputFocus() {
    if (_inputFocus.hasFocus == _inputFocused) return;
    setState(() => _inputFocused = _inputFocus.hasFocus);
  }

  void _confirm() {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    Navigator.of(context).pop(url);
  }

  void _cancel() {
    Navigator.of(context).pop();
  }

  /// D-pad 路由：
  /// - input ↓ → 确定（按钮主操作）
  /// - 按钮 ↑ → input
  /// - 取消 → → 确定；确定 ← → 取消（TextField 内 ←→ 不拦截，光标移动正常）
  /// - Esc/Back/GameB → 取消（任意 focus）
  KeyEventResult _onDialogKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.gameButtonB) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_inputFocus.hasFocus) {
        _confirmFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_confirmFocus.hasFocus || _cancelFocus.hasFocus) {
        _inputFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    // ←→ 仅在按钮间切换；TextField focus 时让光标正常移动
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_confirmFocus.hasFocus) {
        _cancelFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_cancelFocus.hasFocus) {
        _confirmFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.cardBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Focus(
        onKeyEvent: _onDialogKey,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('添加配置源', style: AppTypography.headline2),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '支持苹果 CMS API、TVBox 单仓/多仓配置源 URL · ↓ 到按钮',
                style: AppTypography.caption
                    .copyWith(color: AppColors.hintText),
              ),
              const SizedBox(height: AppSpacing.lg),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: _inputFocused
                      ? [
                          BoxShadow(
                            color: AppColors.netflixRed.withAlpha(100),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _inputFocus,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '输入 URL...',
                    hintStyle: AppTypography.body
                        .copyWith(color: AppColors.hintText),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: AppColors.netflixRed,
                        width: 1.5,
                      ),
                    ),
                    filled: true,
                    fillColor: AppColors.surface,
                    isDense: true,
                  ),
                  style: AppTypography.body
                      .copyWith(color: AppColors.primaryText),
                  onSubmitted: (_) => _confirm(),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _DialogButton(
                    label: '取消',
                    focusNode: _cancelFocus,
                    onActivate: _cancel,
                    primary: false,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  _DialogButton(
                    label: '确定',
                    focusNode: _confirmFocus,
                    onActivate: _confirm,
                    primary: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  final String label;
  final VoidCallback onActivate;
  final bool primary;
  final FocusNode? focusNode;

  const _DialogButton({
    required this.label,
    required this.onActivate,
    required this.primary,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: 'dialog-btn-$label',
      focusNode: focusNode,
      onActivate: onActivate,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding:
              const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: BoxDecoration(
            color: primary ? AppColors.netflixRed : AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused
                  ? AppColors.primaryText
                  : (primary
                      ? AppColors.netflixRed
                      : AppColors.divider),
              width: focused ? 1.5 : 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(120),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: AppTypography.body.copyWith(
              color: primary
                  ? AppColors.primaryText
                  : AppColors.primaryText,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }
}
