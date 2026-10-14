import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'live_widgets.dart';

class LiveChoiceDialog extends StatefulWidget {
  final String title;
  final List<String> labels;
  final int selected;
  const LiveChoiceDialog({
    super.key,
    required this.title,
    required this.labels,
    this.selected = 0,
  });
  @override
  State<LiveChoiceDialog> createState() => _LiveChoiceDialogState();
}

class _LiveChoiceDialogState extends State<LiveChoiceDialog> {
  final _cancel = FocusNode(debugLabel: 'live:choiceCancel');
  final _list = GlobalKey<LiveFocusListState>();
  @override
  void dispose() {
    _cancel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: AppColors.surface,
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (_cancel.hasFocus &&
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          if (event is KeyDownEvent) _list.currentState?.focusCurrent();
          return KeyEventResult.handled;
        }
        if (isLiveBackKey(event.logicalKey)) {
          if (event is KeyDownEvent) Navigator.pop(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        width: 560,
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(widget.title, style: AppTypography.headline2),
              const SizedBox(height: 16),
              Expanded(
                child: LiveFocusList(
                  key: _list,
                  count: widget.labels.length,
                  label: 'live:choice',
                  autofocusIndex: widget.selected.clamp(
                    0,
                    widget.labels.length - 1,
                  ),
                  itemExtent: 88,
                  onDown: () => _cancel.requestFocus(),
                  onActivate: (index) => Navigator.pop(context, index),
                  itemBuilder: (index, focused) => LiveFocusSurface(
                    focused: focused,
                    selected: index == widget.selected,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.labels[index],
                            style: AppTypography.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (index == widget.selected)
                          const Icon(Icons.check, color: AppColors.netflixRed),
                      ],
                    ),
                  ),
                ),
              ),
              LiveButton(
                label: '取消',
                focusNode: _cancel,
                icon: Icons.close,
                onActivate: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
