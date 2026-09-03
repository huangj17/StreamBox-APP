part of 'search_screen.dart';

typedef _VideoIdentity = ({String site, String id});
_VideoIdentity _videoIdentity(VideoItem video) =>
    (site: video.siteKey, id: video.id);

/// Explicit row/column navigation also reaches cells outside the lazy viewport.
/// Keys include the source so equal video IDs from different sites stay distinct.
class _SearchResultGrid extends ConsumerStatefulWidget {
  final List<VideoItem> items;
  final String? query;
  final VoidCallback onExit;
  final VoidCallback onTop;
  final ValueChanged<VideoItem> onSelected;
  const _SearchResultGrid({
    super.key,
    required this.items,
    required this.query,
    required this.onExit,
    required this.onTop,
    required this.onSelected,
  });

  @override
  ConsumerState<_SearchResultGrid> createState() => _SearchResultGridState();
}

class _SearchResultGridState extends ConsumerState<_SearchResultGrid> {
  final _scroll = ScrollController();
  final _nodes = <_VideoIdentity, FocusNode>{};
  late List<VideoItem> _items;
  _VideoIdentity? _current;
  int _columns = 1;
  double _rowExtent = 300;
  int _focusEpoch = 0;

  void _readItems() {
    final seen = <_VideoIdentity>{};
    _items = widget.items
        .where((video) => seen.add(_videoIdentity(video)))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _readItems();
  }

  @override
  void didUpdateWidget(covariant _SearchResultGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final focused = _nodes[_current]?.hasFocus == true;
    final previousIndex = _items.indexWhere(
      (video) => _videoIdentity(video) == _current,
    );
    _readItems();
    if (oldWidget.query != widget.query) {
      _focusEpoch++;
      _current = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (_current != null) {
      final nextIndex = _items.indexWhere(
        (video) => _videoIdentity(video) == _current,
      );
      if (focused && nextIndex != previousIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (nextIndex < 0) {
            widget.onExit();
          } else {
            _focusIndex(nextIndex);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _node(VideoItem video) => _nodes.putIfAbsent(
    _videoIdentity(video),
    () => FocusNode(debugLabel: 'search-video-${video.siteKey}-${video.id}'),
  );

  void focusCurrent() {
    final index = _items.indexWhere(
      (video) => _videoIdentity(video) == _current,
    );
    _focusIndex(index < 0 ? 0 : index);
  }

  void _focusIndex(int index) {
    if (_items.isEmpty) return;
    index = index.clamp(0, _items.length - 1);
    final video = _items[index];
    final node = _node(video);
    _current = _videoIdentity(video);
    final epoch = ++_focusEpoch;
    if (node.context != null) {
      node.requestFocus();
      return;
    }
    if (_scroll.hasClients) {
      final offset = (index ~/ _columns) * _rowExtent;
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && epoch == _focusEpoch && node.context != null) {
        node.requestFocus();
      }
    });
  }

  KeyEventResult _move(int index, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index % _columns == 0) {
        widget.onExit();
      } else {
        _focusIndex(index - 1);
      }
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (index % _columns < _columns - 1 && index + 1 < _items.length) {
        _focusIndex(index + 1);
      }
    } else if (key == LogicalKeyboardKey.arrowUp) {
      if (index < _columns) {
        widget.onTop();
      } else {
        _focusIndex(index - _columns);
      }
    } else if (key == LogicalKeyboardKey.arrowDown) {
      if (index ~/ _columns < (_items.length - 1) ~/ _columns) {
        _focusIndex((index + _columns).clamp(0, _items.length - 1));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final sourceNames = {
      for (final site in ref.watch(sitesProvider)) site.key: site.name,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - 8;
        const gap = 16.0;
        const minCardWidth = 200.0;
        _columns = ((width + gap) / (minCardWidth + gap)).floor().clamp(2, 6);
        final cardWidth = (width - gap * (_columns - 1)) / _columns;
        final scale = MediaQuery.textScalerOf(context);
        final height =
            (cardWidth - 4) * 1.5 +
            scale.scale(18) * 2.6 +
            scale.scale(15) * 1.4 +
            24;
        _rowExtent = height + gap;
        return GridView.builder(
          key: const ValueKey('search-result-grid'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            mainAxisExtent: height,
            crossAxisSpacing: gap,
            mainAxisSpacing: gap,
          ),
          itemCount: _items.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<_VideoIdentity>) return null;
            final index = _items.indexWhere(
              (video) => _videoIdentity(video) == key.value,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) {
            final video = _items[index];
            final identity = _videoIdentity(video);
            return Focus(
              key: ValueKey(identity),
              canRequestFocus: false,
              onKeyEvent: (_, event) => _move(index, event),
              child: Semantics(
                button: true,
                label:
                    '${video.title}，${sourceNames[video.siteKey] ?? ''}，确认查看详情',
                child: TvFocusable(
                  focusNode: _node(video),
                  onActivate: () => widget.onSelected(video),
                  onFocusChange: (focused) {
                    if (focused) _current = identity;
                  },
                  builder: (context, focused) => MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: focused
                            ? const Color(0xFF34343B)
                            : const Color(0xFF1C1C20),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: focused ? Colors.white : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ResolvableCover(
                                  directUrl: video.cover,
                                  title: video.title,
                                  year: video.year,
                                  seed: '${video.siteKey}:${video.id}',
                                  memCacheWidth: 400,
                                ),
                                if (video.remarks?.isNotEmpty == true)
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    left: 8,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withAlpha(190),
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                        ),
                                        child: Text(
                                          video.remarks!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTypography.caption.copyWith(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  height: scale.scale(18) * 2.6,
                                  child: Text(
                                    video.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.body.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.query == null
                                      ? (video.year ?? '最近更新')
                                      : sourceNames[video.siteKey] ?? '未知片源',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.caption.copyWith(
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
