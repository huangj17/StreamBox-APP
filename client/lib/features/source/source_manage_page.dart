import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/local/source_storage.dart';
import '../../data/models/site.dart';
import '../../data/models/source_config.dart';
import '../../data/models/warehouse.dart';
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
  final _urlController = TextEditingController();
  String? _error;
  bool _loading = false;
  String? _loadingUrl; // 正在加载的源 URL
  bool _builtInExpanded = true; // 内置片源是否展开（默认展开）

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addSource() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // 保存 URL
      final urls = ref.read(savedSourceUrlsProvider);
      if (!urls.contains(url)) {
        ref.read(savedSourceUrlsProvider.notifier).state = [...urls, url];
      }

      // 存储到 Hive
      final storage = ref.read(sourceStorageProvider);
      await storage.add(url);

      // 选中并加载
      ref.read(selectedSourceUrlProvider.notifier).state = url;
      await storage.setSelected(url);

      // JAR Bridge URL：直接加载
      if (url.contains(':9978')) {
        await ref.read(sourceConfigProvider.future);
        syncSitesToHome(ref);
        _urlController.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bridge 源加载成功')),
          );
        }
        setState(() => _loading = false);
        return;
      }

      // 等待多仓检测
      final warehouses = await ref.read(warehouseListProvider.future);

      if (warehouses.isNotEmpty) {
        // 多仓：提示用户选择仓库
        _urlController.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('多仓源已加载，共 ${warehouses.length} 个仓库，请选择')),
          );
        }
      } else {
        // 单仓：直接加载
        await ref.read(sourceConfigProvider.future);
        syncSitesToHome(ref);
        _urlController.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('配置源加载成功')),
          );
        }
      }
    } catch (e) {
      setState(() => _error = '加载失败: $e');
    } finally {
      setState(() => _loading = false);
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

    final addInput = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('添加配置源', style: AppTypography.headline2),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '支持苹果 CMS API、TVBox 单仓/多仓配置源 URL',
          style: AppTypography.caption,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  hintText: '输入 URL...',
                  hintStyle:
                      AppTypography.body.copyWith(color: AppColors.hintText),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: AppColors.cardBackground,
                  isDense: true,
                ),
                style: AppTypography.body
                    .copyWith(color: AppColors.primaryText),
                onSubmitted: (_) => _addSource(),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            ElevatedButton(
              onPressed: _loading ? null : _addSource,
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('添加'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!,
              style: AppTypography.caption.copyWith(color: AppColors.error)),
        ],
      ],
    );

    final body = Padding(
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

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('配置源管理')),
      body: body,
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

class _WarehouseChip extends StatefulWidget {
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
  State<_WarehouseChip> createState() => _WarehouseChipState();
}

class _WarehouseChipState extends State<_WarehouseChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.netflixRed.withAlpha(30)
                : AppColors.cardBackground,
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: widget.isSelected || _focused
                  ? AppColors.netflixRed
                  : AppColors.divider,
              width: 1,
            ),
            boxShadow: _focused
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
              if (widget.isLoading) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: widget.isSelected
                        ? AppColors.netflixRed
                        : AppColors.primaryText,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.name,
                style: AppTypography.caption.copyWith(
                  color: widget.isSelected
                      ? AppColors.netflixRed
                      : AppColors.primaryText,
                  fontWeight:
                      widget.isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 可聚焦的「内置片源」折叠行：标题 + 计数 + 展开箭头
class _ExpandToggleRow extends StatefulWidget {
  final bool expanded;
  final int count;
  final VoidCallback onToggle;

  const _ExpandToggleRow({
    required this.expanded,
    required this.count,
    required this.onToggle,
  });

  @override
  State<_ExpandToggleRow> createState() => _ExpandToggleRowState();
}

class _ExpandToggleRowState extends State<_ExpandToggleRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onToggle();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onToggle,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: _focused ? AppColors.netflixRed : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('内置片源', style: AppTypography.headline2),
              const SizedBox(width: AppSpacing.xs),
              _InfoChip('${widget.count} 个', AppColors.hintText),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                widget.expanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
                color: _focused
                    ? AppColors.netflixRed
                    : AppColors.hintText,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 源列表 Tile ──

class _SourceTile extends StatefulWidget {
  final String url;
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
    this.onDelete,
  });

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final name = SourceStorage.nameOf(widget.url);
    final desc = SourceStorage.descOf(widget.url);

    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: widget.isSelected || _focused
              ? AppColors.surface
              : AppColors.cardBackground,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            // 焦点态 = 选中态 = 红边（都已是重点可操作状态），
            // 焦点态额外用阴影和选中态区分
            color: widget.isSelected || _focused
                ? AppColors.netflixRed
                : Colors.transparent,
            width: 1,
          ),
          boxShadow: _focused
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
          url: widget.url,
          name: name,
          desc: desc,
          isSelected: widget.isSelected,
          isLoading: widget.isLoading,
          isMultiWarehouse: widget.isMultiWarehouse,
          onTap: widget.onTap,
          onDelete: widget.onDelete,
        ),
      ),
    );
  }
}

/// 把原 ListTile 抽到独立组件，便于 _SourceTile 外包一层 Focus 后复用
class _SourceTileInner extends StatelessWidget {
  final String url;
  final String name;
  final String? desc;
  final bool isSelected;
  final bool isLoading;
  final bool isMultiWarehouse;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _SourceTileInner({
    required this.url,
    required this.name,
    required this.desc,
    required this.isSelected,
    required this.isLoading,
    required this.isMultiWarehouse,
    required this.onTap,
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
                color: AppColors.primaryText,
                fontWeight: FontWeight.w600,
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
        subtitle: null,
        trailing: onDelete != null
            ? IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.hintText),
                onPressed: onDelete,
              )
            : null,
        onTap: onTap,
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

class _BridgeChip extends StatefulWidget {
  final String name;
  final bool isSelected;
  final VoidCallback onTap;

  const _BridgeChip({
    required this.name,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_BridgeChip> createState() => _BridgeChipState();
}

class _BridgeChipState extends State<_BridgeChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppColors.netflixRed
                : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.isSelected || _focused
                  ? AppColors.netflixRed
                  : AppColors.divider,
            ),
            boxShadow: _focused
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
            widget.name,
            style: AppTypography.caption.copyWith(
              color: widget.isSelected ? Colors.white : AppColors.primaryText,
              fontWeight:
                  widget.isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
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
