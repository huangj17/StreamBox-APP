import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/video_item.dart';
import '../home/providers/categories_provider.dart';
import '../home/widgets/video_card.dart';
import 'providers/search_provider.dart';

/// 搜索页
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasSearched = false;
  bool _autofocusFirstResult = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _search([String? keyword]) {
    final kw = keyword ?? _controller.text.trim();
    if (kw.isEmpty) return;
    if (keyword != null) _controller.text = kw;
    setState(() {
      _hasSearched = true;
      _autofocusFirstResult = true;
    });
    ref.read(searchProvider.notifier).search(kw);
    _focusNode.unfocus();
  }

  void _clearSearch() {
    _controller.clear();
    setState(() {
      _hasSearched = false;
      _autofocusFirstResult = false;
    });
    ref.read(searchProvider.notifier).clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _handleBack() {
    if (_hasSearched) {
      _clearSearch();
      return;
    }
    if (context.canPop()) context.pop();
  }

  void _navigateToDetail(VideoItem video) {
    final sites = ref.read(sitesProvider);
    try {
      final site = sites.firstWhere((s) => s.key == video.siteKey);
      context.push('/detail', extra: {
        'site': site,
        'videoId': video.id,
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchProvider);
    final isCompact = MediaQuery.sizeOf(context).width < 600;
    final hPad = isCompact ? AppSpacing.md : AppSpacing.xl;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _handleBack,
        const SingleActivator(LogicalKeyboardKey.browserBack): _handleBack,
        const SingleActivator(LogicalKeyboardKey.gameButtonB): _handleBack,
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('搜索')),
        body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 搜索栏 ──
          Padding(
            padding: EdgeInsets.fromLTRB(
              hPad, AppSpacing.md, hPad, AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    decoration: InputDecoration(
                      hintText: '输入影片名称...',
                      hintStyle:
                          AppTypography.body.copyWith(color: AppColors.hintText),
                      prefixIcon: const Icon(Icons.search,
                          color: AppColors.hintText),
                      suffixIcon: _hasSearched
                          ? IconButton(
                              icon: const Icon(Icons.close,
                                  color: AppColors.hintText, size: 18),
                              onPressed: _clearSearch,
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppColors.divider),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppColors.divider),
                      ),
                      filled: true,
                      fillColor: AppColors.cardBackground,
                      isDense: true,
                    ),
                    style: AppTypography.body
                        .copyWith(color: AppColors.primaryText),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                ElevatedButton(
                  onPressed: _search,
                  style: ButtonStyle(
                    side: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.focused)) {
                        return const BorderSide(
                            color: AppColors.netflixRed, width: 2);
                      }
                      return null;
                    }),
                    elevation: WidgetStateProperty.resolveWith((states) =>
                        states.contains(WidgetState.focused) ? 8 : 2),
                    shadowColor:
                        WidgetStateProperty.all(AppColors.netflixRed),
                  ),
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),

          // ── 内容区 ──
          Expanded(
            child: _hasSearched
                ? _buildResults(results, hPad)
                : _SearchHome(
                    onKeywordTap: _search,
                    onVideoTap: _navigateToDetail,
                    onTopRowUp: () => _focusNode.requestFocus(),
                    hPad: hPad,
                  ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildResults(AsyncValue<List<VideoItem>> results, double hPad) {
    return results.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: AppColors.netflixRed),
      ),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('搜索失败: $e', style: AppTypography.body),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _search,
              style: ButtonStyle(
                side: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return const BorderSide(
                        color: AppColors.netflixRed, width: 2);
                  }
                  return null;
                }),
                elevation: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.focused) ? 8 : 2),
                shadowColor: WidgetStateProperty.all(AppColors.netflixRed),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '未找到「${_controller.text}」相关内容',
                  style: AppTypography.body,
                ),
                const SizedBox(height: AppSpacing.md),
                ElevatedButton(
                  onPressed: _clearSearch,
                  style: ButtonStyle(
                    side: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.focused)) {
                        return const BorderSide(
                            color: AppColors.netflixRed, width: 2);
                      }
                      return null;
                    }),
                    elevation: WidgetStateProperty.resolveWith((states) =>
                        states.contains(WidgetState.focused) ? 8 : 2),
                    shadowColor:
                        WidgetStateProperty.all(AppColors.netflixRed),
                  ),
                  child: const Text('清空重搜'),
                ),
              ],
            ),
          );
        }
        final autofocusFirst = _autofocusFirstResult;
        if (autofocusFirst) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _autofocusFirstResult = false);
          });
        }
        return _ResultGrid(
          items: items,
          hPad: hPad,
          autofocusFirst: autofocusFirst,
          onItemSelected: _navigateToDetail,
        );
      },
    );
  }
}

/// 搜索首页：搜索历史 + 最近更新
class _SearchHome extends ConsumerWidget {
  final void Function(String keyword) onKeywordTap;
  final void Function(VideoItem video) onVideoTap;
  final VoidCallback onTopRowUp;
  final double hPad;

  const _SearchHome({
    required this.onKeywordTap,
    required this.onVideoTap,
    required this.onTopRowUp,
    required this.hPad,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(searchHistoryProvider);
    final latestAsync = ref.watch(latestUpdatesProvider);

    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          hPad, AppSpacing.sm, hPad, AppSpacing.xxl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 搜索历史 ──
            if (history.isNotEmpty) ...[
              Row(
                children: [
                  Text('搜索历史', style: AppTypography.headline2),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      ref.read(searchHistoryStorageProvider).clearAll();
                      ref.invalidate(searchHistoryProvider);
                    },
                    child: Text(
                      '清空',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.hintText),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: history
                    .map((kw) => _HistoryChip(
                          label: kw,
                          onTap: () => onKeywordTap(kw),
                          onDelete: () {
                            ref
                                .read(searchHistoryStorageProvider)
                                .remove(kw);
                            ref.invalidate(searchHistoryProvider);
                          },
                        ))
                    .toList(),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],

            // ── 最近更新 ──
            Text('最近更新', style: AppTypography.headline2),
            const SizedBox(height: AppSpacing.md),
            latestAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.only(top: AppSpacing.xxl),
                child: Center(
                  child:
                      CircularProgressIndicator(color: AppColors.netflixRed),
                ),
              ),
              error: (_, _) => _EmptyAction(
                message: '加载失败',
                actionLabel: '重试',
                onAction: () => ref.invalidate(latestUpdatesProvider),
              ),
              data: (items) {
                if (items.isEmpty) {
                  return _EmptyAction(
                    message: '暂无数据',
                    actionLabel: '刷新',
                    onAction: () => ref.invalidate(latestUpdatesProvider),
                  );
                }
                return _LatestGrid(
                  items: items,
                  hPad: hPad,
                  onTopRowUp: onTopRowUp,
                  onItemSelected: onVideoTap,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态 / 错误态可聚焦兜底
class _EmptyAction extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _EmptyAction({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Row(
        children: [
          Text(
            message,
            style: AppTypography.body.copyWith(color: AppColors.hintText),
          ),
          const SizedBox(width: AppSpacing.md),
          ElevatedButton(
            onPressed: onAction,
            style: ButtonStyle(
              side: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return const BorderSide(
                      color: AppColors.netflixRed, width: 2);
                }
                return null;
              }),
              elevation: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.focused) ? 8 : 2),
              shadowColor: WidgetStateProperty.all(AppColors.netflixRed),
            ),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

/// 搜索历史标签
/// TV 交互：OK = 搜索；长按 OK / 菜单键 / Delete = 删除
class _HistoryChip extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HistoryChip({
    required this.label,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_HistoryChip> createState() => _HistoryChipState();
}

class _HistoryChipState extends State<_HistoryChip> {
  static const _longPressMs = 500;

  bool _focused = false;
  bool _hovered = false;
  DateTime? _selectDownAt;
  bool _longPressFired = false;

  bool get _highlighted => _focused || _hovered;

  bool _isSelectKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA ||
      k == LogicalKeyboardKey.space;

  bool _isDeleteKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.delete ||
      k == LogicalKeyboardKey.backspace ||
      k == LogicalKeyboardKey.contextMenu;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_isDeleteKey(event.logicalKey) && event is KeyDownEvent) {
      widget.onDelete();
      return KeyEventResult.handled;
    }
    if (!_isSelectKey(event.logicalKey)) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _selectDownAt = DateTime.now();
      _longPressFired = false;
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent && !_longPressFired) {
      if (_selectDownAt != null &&
          DateTime.now().difference(_selectDownAt!).inMilliseconds >=
              _longPressMs) {
        _longPressFired = true;
        widget.onDelete();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      final downAt = _selectDownAt;
      final fired = _longPressFired;
      _selectDownAt = null;
      _longPressFired = false;
      if (fired) return KeyEventResult.handled;
      // 兜底：部分平台不发 KeyRepeatEvent，按 KeyUp 间隔判长按
      if (downAt != null &&
          DateTime.now().difference(downAt).inMilliseconds >= _longPressMs) {
        widget.onDelete();
      } else {
        widget.onTap();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: _onKeyEvent,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: _focused
                ? AppColors.netflixRed.withAlpha(60)
                : AppColors.cardBackground,
            borderRadius: BorderRadius.circular(16),
            // 始终保留 2px border 占位，避免 focus 切换时 Wrap 重排抖动
            border: Border.all(
              color: _focused ? AppColors.netflixRed : Colors.transparent,
              width: 2,
            ),
            boxShadow: _highlighted && !_focused
                ? [
                    BoxShadow(
                      color: Colors.black.withAlpha(120),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: widget.onTap,
              onLongPress: widget.onDelete,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      style: AppTypography.body.copyWith(
                        color: AppColors.primaryText,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: widget.onDelete,
                      behavior: HitTestBehavior.opaque,
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: _focused
                            ? AppColors.primaryText
                            : AppColors.hintText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 最近更新网格（不可滚动，嵌入 SingleChildScrollView）
class _LatestGrid extends StatelessWidget {
  final List<VideoItem> items;
  final double hPad;
  final VoidCallback? onTopRowUp;
  final void Function(VideoItem) onItemSelected;

  const _LatestGrid({
    required this.items,
    required this.hPad,
    required this.onItemSelected,
    this.onTopRowUp,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width - hPad * 2;
    final crossAxisCount = AppSpacing.gridColumns(
      MediaQuery.of(context).size.width,
    );
    final spacing = AppSpacing.md;
    final cardWidth = (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
    final cardHeight = cardWidth * (AppSpacing.cardHeight / AppSpacing.cardWidth);

    return Wrap(
      spacing: spacing,
      runSpacing: spacing + 16,
      children: List.generate(items.length, (idx) {
        final video = items[idx];
        return SizedBox(
          width: cardWidth,
          height: cardHeight,
          child: VideoCard(
            video: video,
            onUpEdge: idx < crossAxisCount ? onTopRowUp : null,
            onSelected: () => onItemSelected(video),
            onFocused: () {},
          ),
        );
      }),
    );
  }
}

/// 搜索结果网格
class _ResultGrid extends StatelessWidget {
  final List<VideoItem> items;
  final double hPad;
  final bool autofocusFirst;
  final void Function(VideoItem) onItemSelected;

  const _ResultGrid({
    required this.items,
    required this.hPad,
    required this.onItemSelected,
    this.autofocusFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = AppSpacing.gridColumns(width);

    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        hPad, AppSpacing.lg, hPad, AppSpacing.xxl,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: AppSpacing.cardWidth / AppSpacing.cardHeight,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md + 16, // 留焦点 scale 空间
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final video = items[index];
        return VideoCard(
          video: video,
          autofocus: autofocusFirst && index == 0,
          onSelected: () => onItemSelected(video),
          onFocused: () {},
        );
      },
    );
  }
}
