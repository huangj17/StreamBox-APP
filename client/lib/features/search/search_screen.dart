import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/platform_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/util/site_navigation.dart';
import '../../data/models/video_item.dart';
import '../../widgets/resolvable_cover.dart';
import '../../widgets/tv_focus.dart';
import '../home/providers/categories_provider.dart';
import 'providers/search_provider.dart';

part 'search_widgets.dart';
part 'search_result_grid.dart';

class SearchScreen extends ConsumerStatefulWidget {
  final String? initialKeyword;
  const SearchScreen({super.key, this.initialKeyword});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _queryFocus = FocusNode(debugLabel: 'search-query');
  final _backFocus = FocusNode(debugLabel: 'search-back');
  final _clearFocus = FocusNode(debugLabel: 'search-reset');
  final _manageFocus = FocusNode(debugLabel: 'search-history-manage');
  final _stateFocus = FocusNode(debugLabel: 'search-state-action');
  final _historyNodes = <String, FocusNode>{};
  final _gridKey = GlobalKey<_SearchResultGridState>();
  FocusNode? _lastPanelFocus;
  String? _keyword;
  int _searchEpoch = 0;
  bool _wide = true;
  bool _showHistory = true;

  @override
  void initState() {
    super.initState();
    final keyword = widget.initialKeyword?.trim();
    if (keyword != null && keyword.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(keyword);
      });
    }
  }

  @override
  void dispose() {
    for (final node in [
      _queryFocus,
      _backFocus,
      _clearFocus,
      _manageFocus,
      _stateFocus,
      ..._historyNodes.values,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  void _search(String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final epoch = ++_searchEpoch;
    setState(() => _keyword = trimmed);
    _queryFocus.requestFocus();
    ref.read(searchProvider.notifier).search(trimmed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && epoch == _searchEpoch && _queryFocus.hasFocus) {
        _enterContent();
      }
    });
  }

  void _reset() {
    _searchEpoch++;
    ref.read(searchProvider.notifier).clear();
    setState(() => _keyword = null);
    _queryFocus.requestFocus();
  }

  void _back() {
    if (_keyword != null) {
      _reset();
    } else {
      Navigator.maybePop(context);
    }
  }

  void _enterContent() {
    if (_gridKey.currentState != null) {
      _gridKey.currentState!.focusCurrent();
    } else if (_stateFocus.context != null) {
      _stateFocus.requestFocus();
    }
  }

  void _returnToPanel() {
    final node = _lastPanelFocus;
    (node != null && node.context != null ? node : _queryFocus).requestFocus();
  }

  Future<void> _editQuery() async {
    final origin = FocusManager.instance.primaryFocus;
    final keyword = await showDialog<String>(
      context: context,
      builder: (_) => _SearchQueryDialog(initialValue: _keyword ?? ''),
    );
    if (!mounted) return;
    if (keyword != null) {
      _search(keyword);
    } else {
      (origin?.context != null ? origin! : _queryFocus).requestFocus();
    }
  }

  Future<void> _manageHistory() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _SearchHistoryDialog(),
    );
    if (mounted) _manageFocus.requestFocus();
  }

  KeyEventResult _panelKey(KeyEvent event, List<String> history) {
    if (!_wide || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final nodes = [
      _queryFocus,
      if (_keyword != null) _clearFocus,
      _manageFocus,
      for (final keyword in history) _historyNodes[keyword]!,
    ];
    final index = nodes.indexWhere((node) => node.hasFocus);
    if (index < 0) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _enterContent();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      nodes[(index + 1).clamp(0, nodes.length - 1)].requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      (index == 0 ? _backFocus : nodes[index - 1]).requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final search = ref.watch(searchProvider);
    final latest = ref.watch(latestUpdatesProvider);
    final history = ref.watch(searchHistoryProvider);
    final progress = ref.watch(searchProgressProvider);
    for (final keyword in history) {
      _historyNodes.putIfAbsent(
        keyword,
        () => FocusNode(debugLabel: 'search-history-$keyword'),
      );
    }
    // Only transfer focus from the loading action. A user browsing history or
    // editing a query must not be interrupted by a late or incremental result.
    ref.listen(searchProvider, (previous, next) {
      if (_keyword != null &&
          _stateFocus.hasFocus &&
          next.asData?.value.isNotEmpty == true) {
        final epoch = _searchEpoch;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              epoch == _searchEpoch &&
              ModalRoute.of(context)?.isCurrent == true) {
            _gridKey.currentState?.focusCurrent();
          }
        });
      }
    });

    ref.listen(latestUpdatesProvider, (previous, next) {
      if (_keyword == null &&
          _stateFocus.hasFocus &&
          next.asData?.value.isNotEmpty == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _keyword == null &&
              ModalRoute.of(context)?.isCurrent == true) {
            _gridKey.currentState?.focusCurrent();
          }
        });
      }
    });

    return PopScope(
      canPop: _keyword == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _reset();
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          if (_isSearchBack(event)) {
            _back();
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent &&
              _backFocus.hasFocus &&
              event.logicalKey == LogicalKeyboardKey.arrowDown) {
            _queryFocus.requestFocus();
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent &&
              _stateFocus.hasFocus &&
              event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _returnToPanel();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          // All text entry lives in a dialog; keep the underlying grid stable
          // while the system input method changes the dialog's available area.
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _wide =
                    constraints.maxWidth >= 860 ||
                    (constraints.maxWidth >= 700 &&
                        constraints.maxHeight < 500);
                _showHistory = constraints.maxHeight >= 600;
                final padding = _wide ? 32.0 : 16.0;
                final panel = _buildPanel(history);
                final results = _keyword == null ? latest : search;
                final content = _buildContent(results, progress);
                return Padding(
                  padding: EdgeInsets.fromLTRB(padding, 20, padding, 16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _SearchControl(
                            label: '返回',
                            icon: Icons.arrow_back_rounded,
                            focusNode: _backFocus,
                            onActivate: _back,
                          ),
                          const SizedBox(width: 20),
                          const Text('搜索', style: AppTypography.headline1),
                          if (_wide) ...[
                            const Spacer(),
                            const Text('找到下一部想看的', style: AppTypography.body),
                          ],
                        ],
                      ),
                      const SizedBox(height: 24),
                      Expanded(
                        child: _wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Container(
                                    width: constraints.maxWidth >= 1200
                                        ? 300
                                        : 264,
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF141416),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: panel,
                                  ),
                                  const SizedBox(width: 28),
                                  Expanded(child: content),
                                ],
                              )
                            : Column(
                                children: [
                                  panel,
                                  const SizedBox(height: 20),
                                  Expanded(child: content),
                                ],
                              ),
                      ),
                      if (_wide &&
                          constraints.maxHeight >= 600 &&
                          PlatformService.needsFocusSystem)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Row(
                            children: [
                              const Text(
                                '方向键  移动',
                                style: AppTypography.caption,
                              ),
                              const SizedBox(width: 28),
                              const Text(
                                'OK  输入 / 打开',
                                style: AppTypography.caption,
                              ),
                              const SizedBox(width: 28),
                              const Text(
                                '←  返回搜索区',
                                style: AppTypography.caption,
                              ),
                              const Spacer(),
                              Text(
                                _keyword == null ? '返回  退出搜索' : '返回  结束本次搜索',
                                style: AppTypography.caption,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(List<String> history) {
    final query = _SearchControl(
      label: _keyword ?? '输入影片名称',
      subtitle: _wide ? (_keyword == null ? '按确认键开始输入' : '确认修改关键词') : null,
      icon: Icons.search_rounded,
      selected: _keyword != null,
      focusNode: _queryFocus,
      autofocus: widget.initialKeyword?.trim().isNotEmpty != true,
      onFocus: () => _lastPanelFocus = _queryFocus,
      onActivate: _editQuery,
    );
    Widget historyItem(String keyword) => _SearchControl(
      key: ValueKey(keyword),
      label: keyword,
      icon: _wide ? Icons.history_rounded : null,
      focusNode: _historyNodes[keyword],
      selected: _keyword == keyword,
      onFocus: () => _lastPanelFocus = _historyNodes[keyword],
      onActivate: () => _search(keyword),
    );
    final controls = <Widget>[
      if (_wide) ...[
        const Text('搜索全部已启用片源', style: AppTypography.body),
        const SizedBox(height: 16),
      ],
      if (!_wide && _keyword != null)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: query),
            const SizedBox(width: 10),
            _SearchControl(
              label: '清除',
              focusNode: _clearFocus,
              onActivate: _reset,
            ),
          ],
        )
      else
        query,
      if (_wide && _keyword != null) ...[
        const SizedBox(height: 10),
        _SearchControl(
          label: '返回最近更新',
          icon: Icons.close_rounded,
          focusNode: _clearFocus,
          onFocus: () => _lastPanelFocus = _clearFocus,
          onActivate: _reset,
        ),
      ],
      if (_wide || _showHistory) ...[
        SizedBox(height: _wide ? 24 : 8),
        Row(
          children: [
            const Expanded(child: Text('最近搜索', style: AppTypography.body)),
            _SearchControl(
              label: '管理',
              focusNode: _manageFocus,
              onFocus: () => _lastPanelFocus = _manageFocus,
              onActivate: history.isEmpty ? null : _manageHistory,
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    ];
    final Widget historyBody;
    if (history.isEmpty) {
      historyBody = const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('搜索过的片名会出现在这里', style: AppTypography.caption),
      );
    } else if (_wide) {
      historyBody = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final keyword in history)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: historyItem(keyword),
            ),
        ],
      );
    } else {
      historyBody = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final keyword in history)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: historyItem(keyword),
              ),
          ],
        ),
      );
    }
    final fixedControls = _wide && _showHistory;
    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...controls,
        if (fixedControls)
          Expanded(child: SingleChildScrollView(child: historyBody))
        else if (_wide || _showHistory)
          historyBody,
      ],
    );
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => _panelKey(event, history),
      child: _wide && !fixedControls
          ? SingleChildScrollView(child: panel)
          : panel,
    );
  }

  Widget _buildContent(
    AsyncValue<List<VideoItem>> results,
    ({int completed, int total}) progress,
  ) {
    final searching = _keyword != null;
    final pending =
        searching && (results.isLoading || progress.completed < progress.total);
    final items = results.asData?.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          searching ? '搜索结果' : '最近更新',
          style: _showHistory ? AppTypography.headline2 : AppTypography.title,
        ),
        const SizedBox(height: 6),
        Text(
          searching
              ? pending
                    ? '已找到 ${items?.length ?? 0} 部 · 正在搜索 ${progress.completed}/${progress.total} 个片源'
                    : '找到 ${items?.length ?? 0} 部 · 已搜索 ${progress.total} 个片源'
              : '还没想好看什么？从最近更新开始',
          style: AppTypography.body.copyWith(fontSize: 16),
          maxLines: _showHistory ? 2 : 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 3,
          child: pending
              ? const LinearProgressIndicator(
                  color: AppColors.netflixRed,
                  backgroundColor: AppColors.surface,
                )
              : null,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: results.when(
            skipLoadingOnRefresh: false,
            skipLoadingOnReload: false,
            loading: () => _SearchPlaceholder(
              icon: Icons.search_rounded,
              title: searching ? '正在查找「$_keyword」' : '正在获取最近更新',
              message: searching ? '结果会陆续出现，可以随时修改关键词' : '你也可以从左侧开始搜索',
              actionLabel: '输入影片名称',
              action: _editQuery,
              focusNode: _stateFocus,
            ),
            error: (_, _) => _SearchPlaceholder(
              icon: Icons.wifi_off_rounded,
              title: searching ? '暂时无法完成搜索' : '最近更新加载失败',
              message: '请检查网络后重试，或尝试其他片名',
              actionLabel: '重试',
              focusNode: _stateFocus,
              action: () => searching
                  ? _search(_keyword!)
                  : ref.invalidate(latestUpdatesProvider),
            ),
            data: (items) {
              if (items.isEmpty) {
                final noSources = searching && progress.total == 0;
                return _SearchPlaceholder(
                  icon: noSources
                      ? Icons.dns_outlined
                      : Icons.manage_search_rounded,
                  title: noSources
                      ? '暂无可用的搜索片源'
                      : searching
                      ? '没有找到「$_keyword」'
                      : '暂无最近更新',
                  message: noSources
                      ? '在设置中启用片源，或重新检测后再试'
                      : searching
                      ? '试试更短的片名，或换一个关键词'
                      : '输入片名，搜索你想看的内容',
                  actionLabel: noSources ? '管理片源' : '输入影片名称',
                  action: noSources
                      ? () => context.push('/settings')
                      : _editQuery,
                  focusNode: _stateFocus,
                );
              }
              return _SearchResultGrid(
                key: _gridKey,
                items: items,
                query: _keyword,
                onExit: _returnToPanel,
                onTop: () => _queryFocus.requestFocus(),
                onSelected: (video) => navigateToVideoDetail(
                  context,
                  ref,
                  siteKey: video.siteKey,
                  videoId: video.id,
                  title: video.title,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
