part of 'source_manage_page.dart';

String _sourceSyncTime(DateTime? time, {bool compact = false}) {
  if (time == null) return '尚未同步';
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${compact ? '' : '${local.year}-'}'
      '${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _SourceSyncSummary extends StatelessWidget {
  final SourceGroup group;
  const _SourceSyncSummary({required this.group});

  @override
  Widget build(BuildContext context) {
    final status = group.loading
        ? '正在同步…'
        : group.error != null
        ? group.needsInitialSync
              ? '同步失败，暂无缓存'
              : '同步失败，沿用缓存'
        : group.needsInitialSync
        ? '尚未同步'
        : group.syncedAt == null
        ? '已缓存 · 自动更新'
        : '已同步 ${_sourceSyncTime(group.syncedAt, compact: true)} · 自动更新';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: status),
          if (Uri.parse(group.url).scheme == 'http')
            const TextSpan(
              text: ' · HTTP 未加密',
              style: TextStyle(color: AppColors.warning),
            ),
        ],
      ),
      key: const ValueKey('source-sync-summary'),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.body.copyWith(
        color: group.error == null
            ? AppColors.secondaryText
            : AppColors.warning,
      ),
    );
  }
}

/// Long diagnostics stay off the source list, but are fully scrollable by D-pad.
class _SourceSyncDetails extends ConsumerStatefulWidget {
  final String url;
  const _SourceSyncDetails({required this.url});

  @override
  ConsumerState<_SourceSyncDetails> createState() => _SourceSyncDetailsState();
}

class _SourceSyncDetailsState extends ConsumerState<_SourceSyncDetails> {
  final _scroll = ScrollController();
  final _closeFocus = FocusNode(debugLabel: 'source-sync-close');

  @override
  void dispose() {
    _scroll.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  KeyEventResult _readWithRemote(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    if (!_scroll.hasClients) return KeyEventResult.handled;
    final position = _scroll.position;
    final next = (position.pixels + (down ? 120 : -120))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if (down && next == position.pixels) {
      _closeFocus.requestFocus();
    } else {
      _scroll.animateTo(
        next,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final group = ref.watch(sourceLibraryProvider).groups[widget.url];
    final info = [
      '配置版本：${group?.version ?? '—'}',
      '上次同步：${_sourceSyncTime(group?.syncedAt)}',
      '前台每 30 分钟检查，也可选择「立即更新」。',
      '配置地址：${widget.url}',
      if (Uri.parse(widget.url).scheme == 'http')
        'HTTP 明文传输，存在被篡改风险，建议服务器启用 HTTPS。',
      if (group?.error != null) '错误详情：\n${group!.error}',
    ].join('\n\n');
    return _SourceDialog(
      title: '同步详情',
      subtitle: '↑↓ 滚动 · 确认或返回关闭',
      scrollController: _scroll,
      children: [
        Focus(
          canRequestFocus: false,
          onKeyEvent: _readWithRemote,
          child: TvFocusable(
            debugLabel: 'source-sync-reader',
            autofocus: true,
            ensureVisibleOnFocus: false,
            onActivate: () => Navigator.pop(context),
            builder: (_, focused) => Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: focused ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Text(info, style: AppTypography.body),
            ),
          ),
        ),
        const SizedBox(height: 20),
        _SourceButton(
          label: '关闭',
          focusNode: _closeFocus,
          onActivate: () => Navigator.pop(context),
        ),
      ],
    );
  }
}
