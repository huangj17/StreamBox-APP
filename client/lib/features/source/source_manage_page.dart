import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/platform/platform_service.dart';
import '../../core/network/url_policy.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(sourceLibraryProvider.notifier).restore();
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
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
    if (mounted) _addFocus.requestFocus();
    if (!mounted || url == null || url.isEmpty) return;
    try {
      if (SourceParser.isJarBridgeUrl(url)) {
        UrlPolicy.requireGatewayUrl(url);
      } else if (SourceParser.isCmsApiUrl(url)) {
        UrlPolicy.requireCmsApiUrl(
          url,
          allowLoopback: SourceParser.isJarBridgePluginUrl(url),
        );
      } else {
        UrlPolicy.requireConfigUrl(url);
      }
      setState(() => _loading = true);
      await ref.read(sourceLibraryProvider.notifier).add(url);
      if (!mounted) return;
      final group = ref.read(sourceLibraryProvider).groups[url];
      setState(() => _selectedGroup = url);
      _setStatus(group?.error ?? '配置源已添加', error: group?.error != null);
    } catch (error) {
      _setStatus('添加失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(sourceLibraryProvider);
    final health = ref.watch(sourceHealthProvider);
    final checking = health.values.any(
      (h) => h.status == SourceHealthStatus.checking,
    );
    final builtIn = library.groups.values
        .where((g) => SourceStorage.isBuiltIn(g.url))
        .toList();
    final collections = library.groups.values
        .where((g) => !SourceStorage.isBuiltIn(g.url))
        .toList();
    final selected = library.groups[_selectedGroup];
    final groups = selected == null ? builtIn : [selected];
    final home = ref.watch(homeSitesProvider).firstOrNull;
    final entryFocus = widget.entryFocusNode ?? _groupFocus;
    final body = LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final header = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                    Text('选择首页内容，管理搜索范围', style: AppTypography.body),
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
            const SizedBox(height: 20),
            _SourceOverview(home: home, enabled: library.activeSites.length),
            const SizedBox(height: 20),
            // Eager children keep off-screen groups reachable with a D-pad.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(3),
              child: Row(
                children: [
                  _SourceButton(
                    label: '内置片源',
                    icon: Icons.inventory_2_outlined,
                    selected: selected == null,
                    focusNode: entryFocus,
                    autofocus: !widget.embedded,
                    onActivate: () => setState(() => _selectedGroup = null),
                  ),
                  for (final group in collections) ...[
                    const SizedBox(width: 12),
                    _SourceButton(
                      key: ValueKey(group.url),
                      label: group.name,
                      icon: Icons.folder_outlined,
                      selected: selected?.url == group.url,
                      onActivate: () =>
                          setState(() => _selectedGroup = group.url),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        );
        final contents = _SourceGroupContents(
          key: ValueKey(selected?.url ?? 'builtin'),
          groups: groups,
          checking: checking,
          onCheck: () => ref.read(sourceHealthProvider.notifier).refreshAll(),
          onRemoved: () {
            if (!mounted) return;
            setState(() => _selectedGroup = null);
            entryFocus.requestFocus();
          },
          onBackToNavigation: widget.onBackToNavigation,
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 32,
            24,
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
        );
      },
    );
    final withStatus = Stack(
      children: [
        body,
        if (_statusMessage != null)
          Positioned(
            bottom: 64,
            left: 24,
            right: 24,
            child: Semantics(
              liveRegion: true,
              child: _StatusBanner(text: _statusMessage!, error: _statusError),
            ),
          ),
      ],
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
