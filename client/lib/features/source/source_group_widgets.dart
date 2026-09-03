part of 'source_manage_page.dart';

/// One group at a time; every source has one remote-control stop.
class _SourceGroupContents extends ConsumerStatefulWidget {
  final List<SourceGroup> groups;
  final bool checking;
  final VoidCallback onCheck;
  final VoidCallback onRemoved;
  final VoidCallback? onBackToNavigation;

  const _SourceGroupContents({
    super.key,
    required this.groups,
    required this.checking,
    required this.onCheck,
    required this.onRemoved,
    this.onBackToNavigation,
  });

  @override
  ConsumerState<_SourceGroupContents> createState() =>
      _SourceGroupContentsState();
}

class _SourceGroupContentsState extends ConsumerState<_SourceGroupContents> {
  bool _showProblems = false;
  String? _error;
  final _filterFocus = FocusNode(debugLabel: 'source-problem-filter');
  final _updateFocus = FocusNode(debugLabel: 'source-update');
  final _detailsFocus = FocusNode(debugLabel: 'source-sync-details');

  @override
  void dispose() {
    _filterFocus.dispose();
    _updateFocus.dispose();
    _detailsFocus.dispose();
    super.dispose();
  }

  Future<void> _showSyncDetails(SourceGroup group) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SourceSyncDetails(url: group.url),
    );
    if (mounted) _detailsFocus.requestFocus();
  }

  Future<void> _remove(SourceGroup group) async {
    final origin = FocusManager.instance.primaryFocus;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _SourceDialog(
        title: '移除配置源？',
        subtitle: '移除「${group.name}」及其片源，共享的官方片源会保留。',
        children: [
          _SourceButton(
            label: '保留配置源',
            icon: Icons.arrow_back_rounded,
            autofocus: true,
            onActivate: () => Navigator.pop(context, false),
          ),
          const SizedBox(height: 12),
          _SourceButton(
            label: '确认移除',
            icon: Icons.delete_outline,
            onActivate: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (!mounted) return;
    origin?.requestFocus();
    if (confirmed != true) return;
    try {
      await ref.read(sourceLibraryProvider.notifier).remove(group.url);
      // Removing the group can already have unmounted this contents widget.
      widget.onRemoved();
    } catch (error) {
      if (mounted) setState(() => _error = '移除失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(sourceLibraryProvider);
    final health = ref.watch(sourceHealthProvider);
    final home = ref.watch(homeSitesProvider).firstOrNull;
    final canonical = {
      for (final site in library.allSites) site.identity: site,
    };
    final seen = <String>{};
    final sites = widget.groups
        .expand((group) => group.config?.sites ?? <Site>[])
        .where((site) => seen.add(site.identity))
        .map((site) => canonical[site.identity] ?? site)
        .toList();
    final group = widget.groups.firstOrNull;
    final builtIn = group == null || SourceStorage.isBuiltIn(group.url);
    final problems = sites
        .where(
          (site) =>
              !site.isSupported ||
              health[site.api]?.status == SourceHealthStatus.unavailable,
        )
        .toList();
    final visible = _showProblems ? problems : sites;
    final loading = widget.groups.any((group) => group.loading);
    final errors = widget.groups
        .map((group) => group.error)
        .whereType<String>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            Text('${sites.length} 个片源', style: AppTypography.title),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (builtIn && group != null)
                  _SourceButton(
                    focusNode: _detailsFocus,
                    label: '详情',
                    icon: Icons.info_outline_rounded,
                    onActivate: () => _showSyncDetails(group),
                  ),
                _SourceButton(
                  label: widget.checking ? '检测中…' : '检测全部',
                  icon: Icons.refresh_rounded,
                  onActivate: widget.checking ? null : widget.onCheck,
                ),
                if (group != null)
                  _SourceButton(
                    focusNode: _updateFocus,
                    label: loading
                        ? '更新中…'
                        : builtIn
                        ? '立即更新'
                        : '更新配置',
                    icon: Icons.sync_rounded,
                    onActivate: loading
                        ? null
                        : () => ref
                              .read(sourceLibraryProvider.notifier)
                              .refresh(group.url),
                  ),
                if (!builtIn)
                  _SourceButton(
                    label: '移除',
                    icon: Icons.delete_outline_rounded,
                    onActivate: () => _remove(group),
                  ),
              ],
            ),
          ],
        ),
        if (builtIn && group != null) ...[
          const SizedBox(height: 10),
          _SourceSyncSummary(group: group),
        ],
        if ((!builtIn && errors.isNotEmpty) || _error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error ?? errors.join('\n'),
              style: AppTypography.body.copyWith(color: AppColors.warning),
            ),
          ),
        if (group != null && group.warehouses.isNotEmpty) ...[
          const SizedBox(height: 16),
          _WarehousePicker(
            warehouses: group.warehouses,
            selectedUrl: group.warehouseUrl,
            loadingUrl: loading ? group.warehouseUrl : null,
            onSelect: (url) => ref
                .read(sourceLibraryProvider.notifier)
                .selectWarehouse(group.url, url),
          ),
        ],
        const SizedBox(height: 16),
        // Keep source order stable when a background health check completes.
        for (final site in visible) ...[
          _SiteRow(
            key: ValueKey(site.identity),
            site: site,
            health: health[site.api],
            home: home?.identity == site.identity,
            officiallyDisabled: library.isOfficiallyDisabled(site.identity),
            onBackToNavigation: widget.onBackToNavigation,
            onUpToActions: site == visible.first
                ? () => _updateFocus.requestFocus()
                : null,
            onRestoreFallback: () {
              if (mounted) _updateFocus.requestFocus();
            },
          ),
          const SizedBox(height: 10),
        ],
        if (visible.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              color: AppColors.cardBackground,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(
                  loading
                      ? Icons.hourglass_empty
                      : Icons.video_library_outlined,
                  size: 36,
                  color: AppColors.secondaryText,
                ),
                const SizedBox(height: 12),
                Text(
                  loading
                      ? '正在加载片源…'
                      : _showProblems
                      ? '没有异常片源'
                      : group?.warehouses.isNotEmpty == true
                      ? '选择一个仓库，查看其中的片源'
                      : group?.needsInitialSync == true
                      ? '尚未获取官方片源，请选择「立即更新」'
                      : '这里还没有片源',
                  textAlign: TextAlign.center,
                  style: AppTypography.body,
                ),
                if (!loading && group == null)
                  const Text('使用上方「添加配置源」开始', style: AppTypography.body),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: _SourceButton(
            focusNode: _filterFocus,
            label: _showProblems ? '显示全部片源' : '异常片源（${problems.length}）',
            icon: _showProblems ? Icons.list_rounded : Icons.tune_rounded,
            selected: _showProblems,
            onActivate: () => setState(() => _showProblems = !_showProblems),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _SiteRow extends StatefulWidget {
  final Site site;
  final SourceHealth? health;
  final bool home;
  final bool officiallyDisabled;
  final VoidCallback? onBackToNavigation;
  final VoidCallback? onUpToActions;
  final VoidCallback onRestoreFallback;

  const _SiteRow({
    super.key,
    required this.site,
    required this.health,
    required this.home,
    this.officiallyDisabled = false,
    required this.onRestoreFallback,
    this.onBackToNavigation,
    this.onUpToActions,
  });

  @override
  State<_SiteRow> createState() => _SiteRowState();
}

class _SiteRowState extends State<_SiteRow> {
  late final _focus = FocusNode(debugLabel: 'source-row-${widget.site.key}');

  @override
  void didUpdateWidget(covariant _SiteRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus) return;
    // A retained keyed row can move without a focus change after an OTA update.
    // Wait for layout, and only scroll if it actually left the viewport.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focus.hasFocus) return;
      final scrollable = Scrollable.maybeOf(context);
      final row = context.findRenderObject();
      final viewport = scrollable?.context.findRenderObject();
      if (scrollable == null || row is! RenderBox || viewport is! RenderBox) {
        return;
      }
      final top = row.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (top >= 0 && top + row.size.height <= viewport.size.height) return;
      scrollable.position.ensureVisible(
        row,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void deactivate() {
    if (_focus.hasFocus) {
      final fallback = widget.onRestoreFallback;
      WidgetsBinding.instance.addPostFrameCallback((_) => fallback());
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _manage() async {
    final fallback = widget.onRestoreFallback;
    await showDialog<void>(
      context: context,
      builder: (_) => _SiteActionsDialog(identity: widget.site.identity),
    );
    if (mounted) {
      _focus.requestFocus();
    } else {
      fallback();
    }
  }

  @override
  Widget build(BuildContext context) {
    final site = widget.site;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowUp &&
            widget.onUpToActions != null) {
          widget.onUpToActions!();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft &&
            widget.onBackToNavigation != null) {
          widget.onBackToNavigation!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        button: true,
        label:
            '${site.name}，${widget.home ? '首页片源，' : ''}'
            '${site.isEnabled ? '已启用' : '已停用'}，确认管理',
        child: TvFocusable(
          focusNode: _focus,
          onActivate: _manage,
          builder: (context, focused) => AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: focused
                  ? const Color(0xFF303036)
                  : AppColors.cardBackground,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: focused
                    ? Colors.white
                    : widget.home
                    ? AppColors.netflixRed.withAlpha(110)
                    : const Color(0xFF29292D),
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: widget.home
                        ? AppColors.netflixRed.withAlpha(30)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    widget.home ? Icons.home_rounded : Icons.dns_outlined,
                    color: widget.home
                        ? const Color(0xFFFF5360)
                        : AppColors.secondaryText,
                    size: 25,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        site.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.title.copyWith(
                          color: AppColors.primaryText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (!site.isSupported)
                            const _InfoChip('暂不兼容', AppColors.warning)
                          else
                            SourceHealthBadge(
                              widget.health ??
                                  SourceHealth.unverified(message: '尚未检测'),
                            ),
                          Text(
                            widget.officiallyDisabled
                                ? '官方已停用'
                                : widget.home
                                ? '首页使用中'
                                : site.isEnabled
                                ? '已启用'
                                : '已停用',
                            style: AppTypography.caption.copyWith(
                              fontSize: 16,
                              color: widget.home
                                  ? const Color(0xFFFF7079)
                                  : AppColors.secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (MediaQuery.sizeOf(context).width >= 1100)
                  Text(focused ? '确认管理' : '管理', style: AppTypography.body),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.secondaryText,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SiteActionsDialog extends ConsumerStatefulWidget {
  final String identity;
  const _SiteActionsDialog({required this.identity});

  @override
  ConsumerState<_SiteActionsDialog> createState() => _SiteActionsDialogState();
}

class _SiteActionsDialogState extends ConsumerState<_SiteActionsDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _save(Future<void> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '操作失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final site = ref
        .watch(sourceLibraryProvider)
        .allSites
        .where((site) => site.identity == widget.identity)
        .firstOrNull;
    if (site == null) {
      return _SourceDialog(
        title: '片源已移除',
        children: [
          _SourceButton(
            label: '返回',
            autofocus: true,
            onActivate: () => Navigator.pop(context),
          ),
        ],
      );
    }
    final health = ref.watch(sourceHealthProvider)[site.api];
    final home =
        ref.watch(homeSitesProvider).firstOrNull?.identity == site.identity;
    final controller = ref.read(sourceLibraryProvider.notifier);
    final officiallyDisabled = ref
        .watch(sourceLibraryProvider)
        .isOfficiallyDisabled(site.identity);
    final canUse =
        site.isSupported &&
        !officiallyDisabled &&
        health?.status != SourceHealthStatus.unavailable;
    return _SourceDialog(
      title: site.name,
      subtitle: officiallyDisabled
          ? '该片源已由官方停用，后续配置恢复后可继续使用'
          : !site.isSupported
          ? '该接口格式或协议暂不支持'
          : health?.message ?? '尚未检测，可以先检测片源是否可用',
      children: [
        _SourceButton(
          label: home ? '首页使用中' : '设为首页片源',
          icon: Icons.home_outlined,
          autofocus: true,
          selected: home,
          onActivate: !canUse || home || _saving
              ? null
              : () => _save(() => controller.selectHome(site)),
        ),
        const SizedBox(height: 12),
        _SourceButton(
          label: officiallyDisabled
              ? '官方已停用'
              : !site.isSupported
              ? '暂不支持启用'
              : site.isEnabled
              ? '停用此片源'
              : '启用此片源',
          icon: site.isEnabled
              ? Icons.toggle_on_outlined
              : Icons.toggle_off_outlined,
          onActivate: !site.isSupported || officiallyDisabled || _saving
              ? null
              : () => _save(() => controller.setEnabled(site, !site.isEnabled)),
        ),
        const SizedBox(height: 12),
        _SourceButton(
          label: health?.status == SourceHealthStatus.checking
              ? '检测中…'
              : '重新检测',
          icon: Icons.refresh_rounded,
          onActivate:
              !site.isSupported || health?.status == SourceHealthStatus.checking
              ? null
              : () => ref.read(sourceHealthProvider.notifier).refreshUrls([
                  site.api,
                ]),
        ),
        const SizedBox(height: 16),
        const Text('首页展示一个片源，搜索汇总所有已启用片源。', style: AppTypography.body),
        if (_error != null)
          Text(
            _error!,
            style: AppTypography.body.copyWith(color: AppColors.warning),
          ),
        const SizedBox(height: 20),
        _SourceButton(
          label: '完成',
          icon: Icons.check_rounded,
          onActivate: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
