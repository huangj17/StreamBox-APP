part of 'search_screen.dart';

bool _isSearchBack(KeyEvent event) =>
    event is KeyDownEvent &&
    (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.browserBack ||
        event.logicalKey == LogicalKeyboardKey.gameButtonB);

class _SearchControl extends StatelessWidget {
  final String label;
  final String? subtitle;
  final IconData? icon;
  final FocusNode? focusNode;
  final VoidCallback? onActivate;
  final VoidCallback? onFocus;
  final bool autofocus;
  final bool selected;
  final bool primary;

  const _SearchControl({
    super.key,
    required this.label,
    required this.onActivate,
    this.subtitle,
    this.icon,
    this.focusNode,
    this.onFocus,
    this.autofocus = false,
    this.selected = false,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onActivate != null,
    selected: selected,
    child: MouseRegion(
      cursor: onActivate == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: TvFocusable(
        focusNode: focusNode,
        debugLabel: 'search-action-$label',
        autofocus: autofocus,
        onActivate: onActivate,
        ensureVisibleOnFocus: false,
        onFocusChange: (focused) {
          if (!focused) return;
          onFocus?.call();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 180),
              );
            }
          });
        },
        builder: (context, focused) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 56, maxWidth: 560),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: primary
                ? AppColors.netflixRed
                : focused
                ? const Color(0xFF34343B)
                : selected
                ? const Color(0xFF361C22)
                : const Color(0xFF222225),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: focused
                  ? Colors.white
                  : selected
                  ? const Color(0xFF96303B)
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 23,
                  color: onActivate == null
                      ? AppColors.secondaryText
                      : AppColors.primaryText,
                ),
                const SizedBox(width: 12),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.body.copyWith(
                        color: onActivate == null
                            ? AppColors.secondaryText
                            : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 6),
                      Text(subtitle!, style: AppTypography.caption),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SearchPlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback action;
  final FocusNode focusNode;
  const _SearchPlaceholder({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.action,
    required this.focusNode,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: const Color(0xFFFF5964)),
          const SizedBox(height: 20),
          Text(title, textAlign: TextAlign.center, style: AppTypography.title),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center, style: AppTypography.body),
          const SizedBox(height: 24),
          _SearchControl(
            label: actionLabel,
            focusNode: focusNode,
            onActivate: action,
          ),
        ],
      ),
    ),
  );
}

class _SearchDialog extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _SearchDialog({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xFF1C1C20),
    insetPadding: EdgeInsets.symmetric(
      horizontal: 20,
      vertical:
          MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom <
              200
          ? 8
          : 20,
    ),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xFF3B3B42)),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          if (_isSearchBack(event)) {
            Navigator.pop(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: AppTypography.headline2),
              const SizedBox(height: 10),
              Text(subtitle, style: AppTypography.body),
              const SizedBox(height: 24),
              child,
            ],
          ),
        ),
      ),
    ),
  );
}

class _SearchQueryDialog extends StatefulWidget {
  final String initialValue;
  const _SearchQueryDialog({required this.initialValue});
  @override
  State<_SearchQueryDialog> createState() => _SearchQueryDialogState();
}

class _SearchQueryDialogState extends State<_SearchQueryDialog> {
  late final _controller = TextEditingController(text: widget.initialValue);
  final _input = FocusNode(debugLabel: 'search-input');
  final _submit = FocusNode(debugLabel: 'search-submit');
  final _cancel = FocusNode(debugLabel: 'search-cancel');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _input.dispose();
    _submit.dispose();
    _cancel.dispose();
    super.dispose();
  }

  void _search() {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) {
      setState(() => _error = '先输入想看的影片名称');
      _input.requestFocus();
      return;
    }
    Navigator.pop(context, keyword);
  }

  @override
  Widget build(BuildContext context) => _SearchDialog(
    title: '想看什么？',
    subtitle: '输入影片名称，或试试更简短的关键词',
    child: Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (_input.hasFocus &&
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _submit.requestFocus();
          return KeyEventResult.handled;
        }
        if ((_submit.hasFocus || _cancel.hasFocus) &&
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _input.requestFocus();
          return KeyEventResult.handled;
        }
        if (_submit.hasFocus &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _cancel.requestFocus();
          return KeyEventResult.handled;
        }
        if (_cancel.hasFocus &&
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _submit.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            focusNode: _input,
            autofocus: true,
            textInputAction: TextInputAction.search,
            style: AppTypography.title,
            decoration: InputDecoration(
              hintText: '例如：庆余年',
              labelText: '影片名称',
              floatingLabelStyle: AppTypography.body,
              hintStyle: AppTypography.body,
              errorText: _error,
              errorMaxLines: 2,
              errorStyle: AppTypography.caption.copyWith(
                color: const Color(0xFFFF8088),
              ),
              filled: true,
              fillColor: AppColors.surface,
              contentPadding: const EdgeInsets.all(18),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.white, width: 2),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFFF8088)),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.white, width: 2),
              ),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 12,
            children: [
              _SearchControl(
                label: '取消',
                focusNode: _cancel,
                onActivate: () => Navigator.pop(context),
              ),
              _SearchControl(
                label: '搜索',
                icon: Icons.search_rounded,
                focusNode: _submit,
                primary: true,
                onActivate: _search,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _SearchHistoryDialog extends ConsumerStatefulWidget {
  const _SearchHistoryDialog();
  @override
  ConsumerState<_SearchHistoryDialog> createState() =>
      _SearchHistoryDialogState();
}

class _SearchHistoryDialogState extends ConsumerState<_SearchHistoryDialog> {
  final _nodes = <String, FocusNode>{};
  final _done = FocusNode(debugLabel: 'search-history-done');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final node in [..._nodes.values, _done]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _delete(String? keyword) async {
    if (_saving) return;
    final history = ref.read(searchHistoryProvider);
    final index = keyword == null ? 0 : history.indexOf(keyword);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final storage = ref.read(searchHistoryStorageProvider);
      if (keyword == null) {
        await storage.clearAll();
      } else {
        await storage.remove(keyword);
      }
      if (!mounted) return;
      ref.invalidate(searchHistoryProvider);
      final remaining = ref.read(searchHistoryProvider);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        (remaining.isEmpty
                ? _done
                : _nodes[remaining[index.clamp(0, remaining.length - 1)]]!)
            .requestFocus();
      });
    } catch (_) {
      if (mounted) setState(() => _error = '未能删除记录，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(searchHistoryProvider);
    for (final keyword in history) {
      _nodes.putIfAbsent(
        keyword,
        () => FocusNode(debugLabel: 'history-delete-$keyword'),
      );
    }
    return _SearchDialog(
      title: '管理搜索历史',
      subtitle: '选择记录，按确认键删除',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < history.length; i++) ...[
            _SearchControl(
              key: ValueKey(history[i]),
              label: history[i],
              icon: Icons.delete_outline,
              focusNode: _nodes[history[i]],
              autofocus: i == 0,
              onActivate: _saving ? null : () => _delete(history[i]),
            ),
            const SizedBox(height: 10),
          ],
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('搜索历史已清空', style: AppTypography.body),
            ),
          if (_error != null)
            Text(
              _error!,
              style: AppTypography.body.copyWith(color: AppColors.warning),
            ),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SearchControl(
              label: '清空全部记录',
              icon: Icons.delete_sweep_outlined,
              onActivate: _saving ? null : () => _delete(null),
            ),
            const SizedBox(height: 12),
          ],
          _SearchControl(
            label: '完成',
            focusNode: _done,
            autofocus: history.isEmpty,
            onActivate: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
