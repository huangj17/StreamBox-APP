import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'live_catalog.dart';
import 'live_choice_dialog.dart';
import 'live_widgets.dart';

/// The picture keeps playing while the remote browses groups and channels.
class LiveChannelPanel extends StatefulWidget {
  final LiveCatalog catalog;
  final int currentStation;
  final ValueChanged<int> onSelect;
  final VoidCallback onClose;
  const LiveChannelPanel({
    super.key,
    required this.catalog,
    required this.currentStation,
    required this.onSelect,
    required this.onClose,
  });
  @override
  State<LiveChannelPanel> createState() => _LiveChannelPanelState();
}

class _LiveChannelPanelState extends State<LiveChannelPanel> {
  final _groups = GlobalKey<LiveFocusListState>();
  final _channels = GlobalKey<LiveFocusListState>();
  final _close = FocusNode(debugLabel: 'livePlayer:close');
  final _groupButton = FocusNode(debugLabel: 'livePlayer:groupButton');
  String? _group;

  @override
  void initState() {
    super.initState();
    _group = widget
        .catalog
        .channels[widget.catalog.stations[widget.currentStation].lines.first]
        .group;
  }

  @override
  void dispose() {
    _close.dispose();
    _groupButton.dispose();
    super.dispose();
  }

  int _currentIn(List<int> stations) {
    final index = stations.indexOf(widget.currentStation);
    return index < 0 ? 0 : index;
  }

  void _selectGroup(String? group) {
    setState(() => _group = group);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _channels.currentState?.focusAt(
          _currentIn(widget.catalog.stationIndices(_group)),
        );
      }
    });
  }

  Future<void> _pickGroup() async {
    final groups = widget.catalog.groups;
    final index = await showDialog<int>(
      context: context,
      builder: (_) => LiveChoiceDialog(
        title: '频道分组',
        labels: ['全部频道', ...groups],
        selected: _group == null ? 0 : groups.indexOf(_group!) + 1,
      ),
    );
    if (!mounted) return;
    if (index != null) {
      _selectGroup(index == 0 ? null : groups[index - 1]);
    } else {
      _groupButton.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 760 || size.height < 500;
    final groups = widget.catalog.groups;
    final stations = widget.catalog.stationIndices(_group);
    final extent = MediaQuery.textScalerOf(context).scale(22) > 28
        ? 104.0
        : 88.0;
    return Container(
      width: compact
          ? double.infinity
          : MediaQuery.sizeOf(context).width * 0.72,
      constraints: const BoxConstraints(maxWidth: 880),
      color: AppColors.deepBlack.withAlpha(248),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(compact ? 16 : 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('频道', style: AppTypography.headline2),
              const SizedBox(height: 8),
              Text(
                '${stations.length} 个频道 · ${_group ?? '全部频道'}',
                style: AppTypography.body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              Focus(
                canRequestFocus: false,
                onKeyEvent: (_, event) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                    if (event is KeyDownEvent) {
                      _channels.currentState?.focusCurrent();
                    }
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (compact)
                      LiveButton(
                        label: '选择分组',
                        icon: Icons.filter_list,
                        focusNode: _groupButton,
                        onActivate: _pickGroup,
                      ),
                    LiveButton(
                      label: '返回直播',
                      icon: Icons.close,
                      focusNode: _close,
                      onActivate: widget.onClose,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  children: [
                    if (!compact) ...[
                      SizedBox(
                        width: 200,
                        child: LiveFocusList(
                          key: _groups,
                          count: groups.length + 1,
                          itemExtent: extent,
                          label: 'livePlayer:group',
                          onLeft: widget.onClose,
                          onRight: () => _channels.currentState?.focusCurrent(),
                          onUp: () => _close.requestFocus(),
                          onActivate: (index) => _selectGroup(
                            index == 0 ? null : groups[index - 1],
                          ),
                          itemBuilder: (index, focused) {
                            final group = index == 0 ? null : groups[index - 1];
                            return LiveFocusSurface(
                              focused: focused,
                              selected: group == _group,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      group ?? '全部频道',
                                      style: AppTypography.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (group == _group)
                                    const Icon(
                                      Icons.check,
                                      size: 22,
                                      color: AppColors.netflixRed,
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                    Expanded(
                      child: LiveFocusList(
                        key: _channels,
                        count: stations.length,
                        itemExtent: extent,
                        label: 'livePlayer:channel',
                        autofocusIndex: _currentIn(stations),
                        onLeft: () {
                          if (compact) {
                            _groupButton.requestFocus();
                          } else {
                            _groups.currentState?.focusAt(
                              _group == null ? 0 : groups.indexOf(_group!) + 1,
                            );
                          }
                        },
                        onRight: widget.onClose,
                        onUp: () => _close.requestFocus(),
                        onActivate: (index) => widget.onSelect(stations[index]),
                        itemBuilder: (index, focused) => LiveChannelTile(
                          channel:
                              widget.catalog.channels[widget
                                  .catalog
                                  .stations[stations[index]]
                                  .lines
                                  .first],
                          number: stations[index] + 1,
                          focused: focused,
                          selected: stations[index] == widget.currentStation,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!compact)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('← 分组 · 确认切台 · 返回收起', style: AppTypography.body),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
