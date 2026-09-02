part of 'source_manage_page.dart';

/// Large targets and a white focus outline, distinct from the red selection.
class _SourceButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onActivate;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool primary;
  final bool selected;

  const _SourceButton({
    super.key,
    required this.label,
    required this.onActivate,
    this.icon,
    this.focusNode,
    this.autofocus = false,
    this.primary = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onActivate != null,
      selected: selected,
      child: TvFocusable(
        focusNode: focusNode,
        debugLabel: 'source-action-$label',
        autofocus: autofocus,
        onActivate: onActivate,
        ensureVisibleOnFocus: false,
        onFocusChange: (focused) {
          if (!focused) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            // Group tabs can sit inside both horizontal and vertical scrolling.
            Scrollable.ensureVisible(
              context,
              alignment: 0.5,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
            );
          });
        },
        builder: (context, focused) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 54, maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: primary
                ? AppColors.netflixRed
                : focused
                ? const Color(0xFF38383E)
                : selected
                ? const Color(0xFF3B1E23)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: focused
                  ? Colors.white
                  : selected
                  ? const Color(0xFFAC3541)
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
                  size: 22,
                  color: onActivate == null
                      ? AppColors.secondaryText
                      : Colors.white,
                ),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
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
              ),
              if (selected) ...[
                const SizedBox(width: 10),
                const Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: Color(0xFFFF7079),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceOverview extends StatelessWidget {
  final Site? home;
  final int enabled;
  const _SourceOverview({required this.home, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2B1C20), Color(0xFF1C1C20)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF463038)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final homeInfo = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.home_rounded,
                color: Color(0xFFFF5360),
                size: 30,
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('当前首页片源', style: AppTypography.caption),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        home?.name ?? '暂无可用片源',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.title.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final searchInfo = Text(
            '$enabled 个片源已启用 · 用于聚合搜索',
            style: AppTypography.body.copyWith(fontSize: 16),
          );
          return constraints.maxWidth < 540
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [homeInfo, const SizedBox(height: 16), searchInfo],
                )
              : Row(
                  children: [
                    Expanded(child: homeInfo),
                    const SizedBox(width: 24),
                    searchInfo,
                  ],
                );
        },
      ),
    );
  }
}

class _RemoteHelp extends StatelessWidget {
  const _RemoteHelp();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: const Wrap(
        spacing: 28,
        runSpacing: 8,
        children: [
          Text('↑ ↓  选择片源', style: AppTypography.caption),
          Text('← →  选择分组', style: AppTypography.caption),
          Text('OK  管理', style: AppTypography.caption),
          Text('返回  上一级', style: AppTypography.caption),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final String text;
  final bool error;
  const _StatusBanner({required this.text, required this.error});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                error ? Icons.error_outline : Icons.check_circle_outline,
                color: error ? AppColors.warning : AppColors.success,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: AppTypography.body.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
        const Text('选择仓库', style: AppTypography.title),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var index = 0; index < warehouses.length; index++)
              _SourceButton(
                key: ValueKey(warehouses[index].url),
                label: warehouses[index].url == loadingUrl
                    ? '加载中…'
                    : warehouses[index].name.isEmpty
                    ? '仓库 ${index + 1}'
                    : warehouses[index].name,
                selected: warehouses[index].url == selectedUrl,
                onActivate: () => onSelect(warehouses[index].url),
              ),
          ],
        ),
      ],
    );
  }
}

class SourceHealthBadge extends StatelessWidget {
  final SourceHealth health;
  const SourceHealthBadge(this.health, {super.key});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (health.status) {
      SourceHealthStatus.checking => ('检测中', const Color(0xFF8CB9FF)),
      SourceHealthStatus.available => ('可用', AppColors.success),
      SourceHealthStatus.unavailable => ('不可用', const Color(0xFFFF7079)),
      SourceHealthStatus.unverified => ('待验证', AppColors.secondaryText),
    };
    return _InfoChip(label, color);
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final Color color;
  const _InfoChip(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(color: color, fontSize: 15),
      ),
    );
  }
}

KeyEventResult _dialogBack(BuildContext context, KeyEvent event) {
  if (event is KeyDownEvent &&
      (event.logicalKey == LogicalKeyboardKey.escape ||
          event.logicalKey == LogicalKeyboardKey.browserBack ||
          event.logicalKey == LogicalKeyboardKey.gameButtonB)) {
    Navigator.pop(context);
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

class _SourceDialog extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const _SourceDialog({
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1C1C20),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF3B3B42)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) => _dialogBack(context, event),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: AppTypography.headline2),
                if (subtitle != null) ...[
                  const SizedBox(height: 10),
                  Text(subtitle!, style: AppTypography.body),
                ],
                const SizedBox(height: 24),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog();
  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final _controller = TextEditingController();
  final _inputFocus = FocusNode(debugLabel: 'add-source-input');
  final _cancelFocus = FocusNode(debugLabel: 'add-source-cancel');
  final _confirmFocus = FocusNode(debugLabel: 'add-source-confirm');
  String? _error;

  @override
  void dispose() {
    _inputFocus.dispose();
    _cancelFocus.dispose();
    _confirmFocus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final url = _controller.text.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      setState(() => _error = '请输入完整的 http:// 或 https:// 地址');
      _inputFocus.requestFocus();
      return;
    }
    Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    return _SourceDialog(
      title: '添加配置源',
      subtitle: '支持 CMS 接口、TVBox 配置和 OuonnkiTV 片源列表',
      children: [
        Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (_inputFocus.hasFocus &&
                event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _confirmFocus.requestFocus();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                (_confirmFocus.hasFocus || _cancelFocus.hasFocus)) {
              _inputFocus.requestFocus();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                focusNode: _inputFocus,
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                style: AppTypography.body.copyWith(color: Colors.white),
                decoration: InputDecoration(
                  labelText: '配置源地址',
                  hintText: 'https://example.com/config.json',
                  errorText: _error,
                  errorMaxLines: 2,
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
                ),
                onSubmitted: (_) => _confirm(),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  _SourceButton(
                    label: '取消',
                    focusNode: _cancelFocus,
                    onActivate: () => Navigator.pop(context),
                  ),
                  _SourceButton(
                    label: '添加',
                    icon: Icons.add_rounded,
                    focusNode: _confirmFocus,
                    primary: true,
                    onActivate: _confirm,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
