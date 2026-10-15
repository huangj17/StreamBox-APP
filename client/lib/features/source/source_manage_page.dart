import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/platform/platform_service.dart';
import '../../core/network/url_policy.dart';
import '../../core/network/source_error_message.dart';
import '../../data/local/source_storage.dart';
import '../../data/models/site.dart';
import '../../data/models/source_health.dart';
import '../../data/models/warehouse.dart';
import '../../data/sources/source_parser.dart';
import '../../widgets/tv_focus.dart';
import '../home/providers/categories_provider.dart';
import 'providers/source_provider.dart';
import 'providers/source_library_provider.dart';
part 'source_manage_widgets.dart';
part 'source_group_widgets.dart';
part 'source_sync_widgets.dart';

class SourceManagePage extends ConsumerStatefulWidget {
  final bool embedded;
  final FocusNode? entryFocusNode;
  final VoidCallback? onBackToNavigation;
  const SourceManagePage({
    super.key,
    this.embedded = false,
    this.entryFocusNode,
    this.onBackToNavigation,
  });
  @override
  ConsumerState<SourceManagePage> createState() => _SourceManagePageState();
}

class _SourceManagePageState extends ConsumerState<SourceManagePage> {
  bool _loading = false;
  String? _statusMessage;
  bool _statusError = false;
  Timer? _statusTimer;
  String? _selectedGroup;
  final _addFocus = FocusNode(debugLabel: 'add-source');
  final _groupFocus = FocusNode(debugLabel: 'source-group-builtin');
  final _groupNodes = <String, FocusNode>{};
  final _catalogRetryFocus = FocusNode(debugLabel: 'source-catalog-retry');

  FocusNode get _entryFocus => widget.entryFocusNode ?? _groupFocus;

  void _requestGroupFocus() {
    (_groupNodes[_selectedGroup] ?? _addFocus).requestFocus();
  }

  void _routeEntryFocus() {
    if (_entryFocus.hasPrimaryFocus) _requestGroupFocus();
  }

  @override
  void initState() {
    super.initState();
    _entryFocus.addListener(_routeEntryFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(sourceLibraryProvider.notifier).restore();
    });
  }

  @override
  void didUpdateWidget(covariant SourceManagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entryFocusNode != widget.entryFocusNode) {
      (oldWidget.entryFocusNode ?? _groupFocus).removeListener(
        _routeEntryFocus,
      );
      _entryFocus.addListener(_routeEntryFocus);
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _entryFocus.removeListener(_routeEntryFocus);
    for (final node in _groupNodes.values) {
      node.dispose();
    }
    _catalogRetryFocus.dispose();
    _addFocus.dispose();
    _groupFocus.dispose();
    super.dispose();
  }

  void _setStatus(String message, {bool error = false}) {
    if (!mounted) return;
    _statusTimer?.cancel();
    setState(() {
      _statusMessage = message;
      _statusError = error;
    });
    _statusTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _statusMessage = null);
    });
  }

  Future<void> _openAddSourceDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _AddSourceDialog(),
    );
    if (mounted) {
      _addFocus.requestFocus();
    }
    if (!mounted || url == null || url.isEmpty) return;
    try {
      if (SourceParser.isCmsApiUrl(url)) {
        UrlPolicy.requireCmsApiUrl(url);
      } else {
        if (UrlPolicy.isRetiredBridgeUrl(url)) {
          throw const FormatException(
            '旧 JAR Bridge 已停用，请在 Android 上导入原始 TVBox 配置',
          );
        }
        UrlPolicy.requireConfigUrl(url);
      }
      setState(() => _loading = true);
      await ref.read(sourceLibraryProvider.notifier).add(url);
      if (!mounted) return;
      final group = ref.read(sourceLibraryProvider).groups[url];
      setState(() {
        _selectedGroup = url;
        _statusMessage = null;
      });
      // A failed group already shows its error beside the retry action.
      if (group?.error == null) {
        final library = ref.read(sourceLibraryProvider);
        final imported =
            group?.config?.sites
                .where((s) => s.isVisible)
                .map((s) => s.identity)
                .toSet() ??
            <String>{};
        final shared = imported
            .where((id) => library.originsFor(id).length > 1)
            .length;
        _setStatus('配置源已添加 · ${imported.length - shared} 个新增 · $shared 个重复已合并');
      }
    } catch (error) {
      _setStatus('添加失败：${sourceErrorMessage(error)}', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(sourceLibraryProvider);
    final health = ref.watch(sourceHealthProvider);
    final checking = health.values.any((h) => h.isPending);
    final groups = library.groups.values.toList();
    final previousSelection = _selectedGroup;
    final selected = library.groups[_selectedGroup] ?? groups.firstOrNull;
    _selectedGroup = selected?.url;
    final removedUrls = _groupNodes.keys
        .where((url) => !library.groups.containsKey(url))
        .toList();
    final removedFocus = removedUrls.any((url) => _groupNodes[url]!.hasFocus);
    final lostSelection =
        previousSelection != null &&
        !library.groups.containsKey(previousSelection);
    final fallback =
        removedFocus ||
        (lostSelection &&
            _entryFocus.hasFocus &&
            !_addFocus.hasFocus &&
            !_groupNodes.entries.any(
              (entry) =>
                  library.groups.containsKey(entry.key) && entry.value.hasFocus,
            )) ||
        (_catalogRetryFocus.hasFocus && library.catalogStatus?.error == null);
    for (final url in removedUrls) {
      final node = _groupNodes.remove(url)!;
      WidgetsBinding.instance.addPostFrameCallback((_) => node.dispose());
    }
    for (final group in groups) {
      _groupNodes.putIfAbsent(
        group.url,
        () => FocusNode(debugLabel: 'source-action-${group.name}'),
      );
    }
    if (fallback) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestGroupFocus();
      });
    }
    final home = ref.watch(homeSitesProvider).firstOrNull;
    final catalogError = library.catalogStatus;
    final showCatalogError =
        catalogError?.error != null &&
        !groups.any((group) => SourceStorage.isBuiltIn(group.url));
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final compact = !PlatformService.isTv && constraints.maxWidth < 620;
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!compact)
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 24,
                runSpacing: 16,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('片源管理', style: AppTypography.headline1),
                      const SizedBox(height: 6),
                      Text('重复片源已合并，选择首页内容和搜索范围', style: AppTypography.body),
                    ],
                  ),
                  _SourceButton(
                    label: _loading ? '正在添加…' : '添加配置源',
                    icon: Icons.add_rounded,
                    primary: true,
                    focusNode: _addFocus,
                    onActivate: _loading ? null : _openAddSourceDialog,
                  ),
                ],
              ),
            if (!compact) const SizedBox(height: 20),
            _SourceOverview(home: home, enabled: library.activeSites.length),
            if (compact) ...[
              const SizedBox(height: 12),
              _SourceButton(
                label: _loading ? '正在添加…' : '添加配置源',
                icon: Icons.add_rounded,
                primary: true,
                focusNode: _addFocus,
                onActivate: _loading ? null : _openAddSourceDialog,
              ),
            ],
            SizedBox(height: compact ? 16 : 20),
            if (showCatalogError) ...[
              Text(
                '配置目录：${catalogError!.error}',
                style: _sourceBody(context).copyWith(color: AppColors.warning),
              ),
              const SizedBox(height: 8),
              _SourceButton(
                label: catalogError.loading ? '正在更新目录…' : '重试配置目录',
                icon: Icons.sync_rounded,
                focusNode: _catalogRetryFocus,
                onActivate: catalogError.loading
                    ? null
                    : () => ref
                          .read(sourceLibraryProvider.notifier)
                          .refresh(SourceStorage.officialUrl),
              ),
              const SizedBox(height: 16),
            ],
            // Eager children keep off-screen groups reachable with a D-pad.
            if (groups.isNotEmpty)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(3),
                child: Row(
                  children: [
                    for (var index = 0; index < groups.length; index++) ...[
                      if (index > 0) const SizedBox(width: 12),
                      _SourceButton(
                        key: ValueKey(groups[index].url),
                        label: groups[index].name,
                        icon: Icons.folder_outlined,
                        selected: selected?.url == groups[index].url,
                        focusNode: _groupNodes[groups[index].url],
                        onActivate: () => setState(() {
                          _selectedGroup = groups[index].url;
                        }),
                      ),
                    ],
                  ],
                ),
              ),
            SizedBox(height: compact ? 16 : 20),
          ],
        );
        final contents = _SourceGroupContents(
          key: ValueKey(selected?.url),
          group: selected,
          checking: checking,
          onCheck: () => ref.read(sourceHealthProvider.notifier).refreshAll(),
          onRemoved: () {
            if (!mounted) return;
            setState(() {
              _selectedGroup = null;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _requestGroupFocus();
            });
          },
          onBackToNavigation: widget.onBackToNavigation,
        );
        return _SourceDensity(
          compact: compact,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : 32,
              compact ? 12 : 24,
              compact ? 16 : 32,
              12,
            ),
            child: Column(
              children: [
                Expanded(
                  child: compact || constraints.maxHeight < 520
                      ? SingleChildScrollView(
                          child: Column(children: [header, contents]),
                        )
                      : Column(
                          children: [
                            header,
                            Expanded(
                              child: SingleChildScrollView(child: contents),
                            ),
                          ],
                        ),
                ),
                if (!compact && PlatformService.needsFocusSystem)
                  const _RemoteHelp(),
              ],
            ),
          ),
        );
      },
    );
    final withStatus = Focus(
      focusNode: _entryFocus,
      skipTraversal: true,
      autofocus: !widget.embedded && PlatformService.needsFocusSystem,
      child: Stack(
        children: [
          body,
          if (_statusMessage != null)
            Positioned(
              bottom: 64,
              left: 24,
              right: 24,
              child: Semantics(
                liveRegion: true,
                child: _StatusBanner(
                  text: _statusMessage!,
                  error: _statusError,
                ),
              ),
            ),
        ],
      ),
    );
    if (widget.embedded) return withStatus;
    return Scaffold(
      appBar: AppBar(title: const Text('配置源管理')),
      body: SafeArea(
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.browserBack ||
                    event.logicalKey == LogicalKeyboardKey.gameButtonB)) {
              Navigator.maybePop(context);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: withStatus,
        ),
      ),
    );
  }
}
