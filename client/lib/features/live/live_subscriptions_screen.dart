import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/network/url_policy.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import 'live_widgets.dart';
import 'providers/live_provider.dart';

class LiveSubscriptionsScreen extends ConsumerStatefulWidget {
  const LiveSubscriptionsScreen({super.key});
  @override
  ConsumerState<LiveSubscriptionsScreen> createState() =>
      _LiveSubscriptionsScreenState();
}

class _LiveSubscriptionsScreenState
    extends ConsumerState<LiveSubscriptionsScreen> {
  final _addFocus = FocusNode(debugLabel: 'live:add');
  final _catalogFocus = FocusNode(debugLabel: 'live:catalogRefresh');
  bool _adding = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(liveProvider.notifier).syncCatalog());
    });
  }

  @override
  void dispose() {
    _addFocus.dispose();
    _catalogFocus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_adding) return;
    final value = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _AddLiveDialog(),
    );
    if (!mounted) return;
    _addFocus.requestFocus();
    if (value == null) return;
    setState(() => _adding = true);
    try {
      await ref.read(liveProvider.notifier).add(value.$1, value.$2);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : '保存订阅失败，请重试',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(String name, String url) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除直播订阅'),
        content: Text('移除“$name”及其缓存频道？'),
        actions: [
          LiveButton(
            label: '取消',
            icon: Icons.close,
            autofocus: true,
            onActivate: () => Navigator.pop(context, false),
          ),
          LiveButton(
            label: '移除',
            icon: Icons.delete_outline,
            onActivate: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (remove == true) await ref.read(liveProvider.notifier).remove(url);
    if (mounted) _addFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveProvider);
    ref.listen(liveProvider, (previous, next) {
      if (previous?.catalogSyncedAt == next.catalogSyncedAt) return;
      final node = FocusManager.instance.primaryFocus;
      final label = node?.debugLabel ?? '';
      if (![
        'live:use:',
        'live:subscriptionRefresh:',
        'live:remove:',
      ].any(label.startsWith)) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final anchor = node?.context;
        if (anchor == null || !anchor.mounted) {
          _catalogFocus.requestFocus();
        } else {
          Scrollable.ensureVisible(anchor, alignment: 0.5);
        }
      });
    });
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (isLiveBackKey(event.logicalKey)) {
          if (event is KeyDownEvent) context.pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 760 ? 16 : 40,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('直播设置', style: AppTypography.headline1),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      LiveButton(
                        label: _adding ? '正在添加' : '添加订阅',
                        icon: Icons.add,
                        primary: true,
                        autofocus: true,
                        focusNode: _addFocus,
                        onActivate: _add,
                      ),
                      LiveButton(
                        label: '返回直播',
                        icon: Icons.arrow_back,
                        onActivate: () => context.pop(),
                      ),
                      LiveButton(
                        label: state.catalogLoading ? '正在更新配置' : '更新直播配置',
                        icon: Icons.sync,
                        focusNode: _catalogFocus,
                        onActivate: () => unawaited(
                          ref
                              .read(liveProvider.notifier)
                              .syncCatalog(force: true),
                        ),
                      ),
                      if (state.hiddenOfficialCount > 0)
                        LiveButton(
                          label: '恢复预置订阅',
                          icon: Icons.restore,
                          onActivate: () {
                            _catalogFocus.requestFocus();
                            unawaited(
                              ref.read(liveProvider.notifier).restoreOfficial(),
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '支持 M3U 频道列表订阅。IPv6 频道需要当前网络支持 IPv6。',
                    style: AppTypography.body,
                  ),
                  SizedBox(
                    height: MediaQuery.textScalerOf(context).scale(18) * 3 + 8,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        state.catalogLoading
                            ? '正在同步服务器直播订阅…'
                            : state.catalogError ??
                                  (state.catalogSyncedAt == null
                                      ? '尚未获取服务器直播配置'
                                      : '直播配置已同步 · 自定义订阅单独保留'),
                        style: AppTypography.body.copyWith(
                          color: state.catalogError == null
                              ? AppColors.secondaryText
                              : AppColors.warning,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Column(
                    children: [
                      if (state.subscriptions.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            '暂无订阅，请添加 M3U 地址',
                            style: AppTypography.title,
                          ),
                        ),
                      for (final item in state.subscriptions)
                        Padding(
                          key: ValueKey(item.id ?? item.url),
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: AppColors.cardBackground,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.name, style: AppTypography.title),
                                const SizedBox(height: 8),
                                Text(
                                  item.url,
                                  style: AppTypography.caption,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  state.loading.contains(item.url)
                                      ? '正在刷新频道…'
                                      : state.errors[item.url] ??
                                            '${state.playlists[item.url]?.channels.length ?? 0} 个缓存频道',
                                  style: AppTypography.body.copyWith(
                                    color: state.errors.containsKey(item.url)
                                        ? AppColors.warning
                                        : AppColors.secondaryText,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: [
                                    LiveButton(
                                      label: state.selectedUrl == item.url
                                          ? '当前订阅 · 播放'
                                          : '使用订阅',
                                      icon: state.selectedUrl == item.url
                                          ? Icons.check
                                          : Icons.play_arrow,
                                      debugLabel:
                                          'live:use:${state.subscriptions.indexOf(item)}',
                                      onActivate: () {
                                        unawaited(
                                          ref
                                              .read(liveProvider.notifier)
                                              .select(item.url),
                                        );
                                        context.pop();
                                      },
                                    ),
                                    LiveButton(
                                      label: '刷新',
                                      icon: Icons.refresh,
                                      debugLabel:
                                          'live:subscriptionRefresh:${state.subscriptions.indexOf(item)}',
                                      onActivate: () => unawaited(
                                        ref
                                            .read(liveProvider.notifier)
                                            .refresh(item.url),
                                      ),
                                    ),
                                    LiveButton(
                                      label: '移除',
                                      icon: Icons.delete_outline,
                                      debugLabel:
                                          'live:remove:${state.subscriptions.indexOf(item)}',
                                      onActivate: () =>
                                          _remove(item.name, item.url),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddLiveDialog extends StatefulWidget {
  const _AddLiveDialog();
  @override
  State<_AddLiveDialog> createState() => _AddLiveDialogState();
}

class _AddLiveDialogState extends State<_AddLiveDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'live:inputName');
  final _urlFocus = FocusNode(debugLabel: 'live:inputUrl');
  final _saveFocus = FocusNode(debugLabel: 'live:inputSave');
  final _cancelFocus = FocusNode(debugLabel: 'live:inputCancel');
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    for (final node in [_nameFocus, _urlFocus, _saveFocus, _cancelFocus]) {
      node.dispose();
    }
    super.dispose();
  }

  void _save() {
    try {
      if (_name.text.trim().isEmpty || _name.text.trim().length > 100) {
        throw const FormatException('请输入 1–100 个字符的订阅名称');
      }
      UrlPolicy.requireConfigUrl(_url.text.trim());
      Navigator.pop(context, (_name.text.trim(), _url.text.trim()));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        if (event is KeyDownEvent) {
          if (key == LogicalKeyboardKey.arrowDown) {
            if (_nameFocus.hasFocus) {
              _urlFocus.requestFocus();
            } else if (_urlFocus.hasFocus) {
              _saveFocus.requestFocus();
            }
          } else {
            if (_urlFocus.hasFocus) {
              _nameFocus.requestFocus();
            } else if (_saveFocus.hasFocus || _cancelFocus.hasFocus) {
              _urlFocus.requestFocus();
            }
          }
        }
        return KeyEventResult.handled;
      }
      if (isLiveBackKey(event.logicalKey)) {
        if (event is KeyDownEvent) Navigator.pop(context);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('添加直播订阅'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                focusNode: _nameFocus,
                autofocus: true,
                maxLength: 100,
                style: AppTypography.body.copyWith(color: Colors.white),
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: '订阅名称'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _url,
                focusNode: _urlFocus,
                keyboardType: TextInputType.url,
                style: AppTypography.body.copyWith(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'M3U 地址',
                  hintText: 'https://…/channels.m3u',
                ),
                onSubmitted: (_) => _save(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _error!,
                    style: AppTypography.body.copyWith(
                      color: AppColors.warning,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        LiveButton(
          label: '取消',
          focusNode: _cancelFocus,
          icon: Icons.close,
          onActivate: () => Navigator.pop(context),
        ),
        LiveButton(
          label: '添加',
          focusNode: _saveFocus,
          icon: Icons.add,
          primary: true,
          onActivate: _save,
        ),
      ],
    ),
  );
}
