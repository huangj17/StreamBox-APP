import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/live_channel.dart';
import 'live_catalog.dart';
import 'live_player_screen.dart';
import 'live_widgets.dart';
import 'providers/live_provider.dart';

/// The live destination is the TV picture. Subscription maintenance is a
/// separate route, and returning to it reconnects the last selected channel.
class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});
  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  LivePlaybackRequest? _request;
  bool _editing = false;
  LiveChannel? _resumeChannel;
  String? _resumeUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(liveProvider.notifier).syncCatalog());
      final url = ref.read(liveProvider).selectedUrl;
      if (url != null) {
        unawaited(ref.read(liveProvider.notifier).refreshIfStale(url));
      }
    });
  }

  void _leave() => context.canPop() ? context.pop() : context.go('/');

  Future<void> _settings([int? index]) async {
    if (_editing) return;
    if (_request != null && index != null) {
      _resumeUrl = _request!.subscriptionUrl;
      _resumeChannel = _request!.channels[index];
    }
    // Unmount the player before opening settings: no hidden video/audio behind
    // the route, and no second engine if the subscription changes there.
    setState(() => _editing = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await context.push('/live/subscriptions');
    if (!mounted) return;
    setState(() {
      _request = null;
      _editing = false;
    });
    final url = ref.read(liveProvider).selectedUrl;
    if (url != null) {
      unawaited(ref.read(liveProvider.notifier).refreshIfStale(url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveProvider);
    if (_editing) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final url = state.selectedUrl;
    final awaitingNewEndpoint =
        state.playlist?.updatedAt.millisecondsSinceEpoch == 0 &&
        !state.errors.containsKey(url);
    if (_request?.subscriptionUrl != url) _request = null;
    if (!_editing &&
        _request == null &&
        state.playlist != null &&
        !awaitingNewEndpoint) {
      final channels = liveViewingChannels(state.playlist!.channels);
      if (channels.isNotEmpty && url != null) {
        final last = _resumeUrl == url
            ? _resumeChannel
            : ref.read(liveStorageProvider).lastChannelDetails(url);
        final index = liveResumeIndex(channels, last);
        _request = LivePlaybackRequest(
          channels: channels,
          initialIndex: index,
          subscriptionUrl: url,
          subscriptionName: state.selected!.name,
        );
      }
    }
    if (!_editing && _request != null) {
      return LivePlayerScreen(
        key: ObjectKey(_request),
        request: _request!,
        onExit: _leave,
        onSettings: _settings,
      );
    }
    final loading =
        _editing ||
        state.catalogLoading ||
        state.loading.contains(url) ||
        awaitingNewEndpoint;
    final empty = state.subscriptions.isEmpty;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (isLiveBackKey(event.logicalKey)) {
          if (event is KeyDownEvent) _leave();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    loading ? Icons.live_tv : Icons.tv_off,
                    size: 64,
                    color: AppColors.secondaryText,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    loading
                        ? '正在准备直播'
                        : empty
                        ? '添加订阅，开始看电视'
                        : '暂无可用频道',
                    style: AppTypography.headline2,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    state.catalogError ??
                        state.errors[url] ??
                        state.selected?.name ??
                        '在直播设置中添加 M3U 订阅',
                    style: AppTypography.body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      if (url == null)
                        LiveButton(
                          label: '更新直播配置',
                          icon: Icons.refresh,
                          onActivate: () => unawaited(
                            ref
                                .read(liveProvider.notifier)
                                .syncCatalog(force: true),
                          ),
                        ),
                      if (url != null && !loading)
                        LiveButton(
                          label: '重试',
                          icon: Icons.refresh,
                          autofocus: true,
                          onActivate: () => unawaited(
                            ref.read(liveProvider.notifier).refresh(url),
                          ),
                        ),
                      LiveButton(
                        label: '直播设置',
                        icon: Icons.settings_outlined,
                        autofocus: empty || loading,
                        onActivate: _settings,
                      ),
                      LiveButton(
                        label: '返回',
                        icon: Icons.arrow_back,
                        onActivate: _leave,
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
