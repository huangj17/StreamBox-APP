import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/video_item.dart';
import '../../data/models/video_aggregation.dart';
import '../../data/models/episode.dart';
import '../../data/models/playback_resume.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focus.dart';
import '../home/providers/categories_provider.dart';
import 'detail_screen.dart';
import 'providers/aggregate_detail_provider.dart';

class AggregateDetailScreen extends ConsumerStatefulWidget {
  final VideoItem video;
  const AggregateDetailScreen({super.key, required this.video});

  @override
  ConsumerState<AggregateDetailScreen> createState() =>
      _AggregateDetailScreenState();
}

class _AggregateDetailScreenState extends ConsumerState<AggregateDetailScreen> {
  final _switchFocus = FocusNode(debugLabel: 'detail-source-switch');
  String? _selected;
  PlaybackResume? _resume;

  @override
  void dispose() {
    _switchFocus.dispose();
    super.dispose();
  }

  Future<void> _chooseSource() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) =>
          _SourceChoiceDialog(video: widget.video, selected: _selected),
    );
    if (!mounted) return;
    if (selected != null && selected != _selected) {
      final target = ref
          .read(aggregateDetailProvider(widget.video))
          .resolved
          .where((s) => s.identity == selected)
          .firstOrNull;
      final resume = _resume;
      if (target != null && resume != null) {
        final groups = target.detail.episodeGroups;
        final match = matchingEpisodeLocation(
          groups,
          resume.episodeName,
          preferredGroupIndex: target.recommendedGroup,
          playable: (ep) => canPlayEpisode(target.site, ep),
        );
        if (match == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '「${target.site.name}」没有可匹配的「${resume.episodeName}」，已保留当前片源',
              ),
            ),
          );
        } else {
          setState(() {
            _resume = resume.at(
              match,
              groups[match.groupIndex][match.episodeIndex].name,
            );
            _selected = selected;
          });
        }
      } else if (target != null) {
        setState(() => _selected = selected);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _switchFocus.context != null) _switchFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aggregateDetailProvider(widget.video));
    _selected ??= state.initialSelection;
    if (_resume == null &&
        !state.loading &&
        state.failures.containsKey(_selected)) {
      _selected = state.firstAvailableIdentity;
    }
    final selection = state.resolved
        .where((s) => s.identity == _selected)
        .firstOrNull;
    if (selection == null) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.loading) const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(
                    state.loading ? '正在加载影片详情' : '暂未找到可播放的片源',
                    style: AppTypography.headline2,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '已加载 ${state.completed}/${state.candidates.length} 个片源',
                    style: AppTypography.body,
                  ),
                  const SizedBox(height: 24),
                  TvActionButton.secondary(
                    label: '查看片源 / 重试',
                    debugLabel: 'aggregate-retry',
                    onActivate: _chooseSource,
                  ),
                  const SizedBox(height: 12),
                  TvActionButton.secondary(
                    label: '返回',
                    autofocus: true,
                    debugLabel: 'aggregate-back',
                    onActivate: () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return DetailScreen(
      key: ValueKey(selection.identity),
      site: selection.site,
      videoId: selection.video.id,
      preloadedDetail: selection.detail,
      defaultGroupIndex: selection.recommendedGroup,
      initialGroupIndex: _resume?.groupIndex,
      initialEpisodeIndex: _resume?.episodeIndex,
      initialPositionMs: _resume?.positionMs,
      onPlaybackResumeChanged: (resume) {
        if (_selected == selection.identity) _resume = resume;
      },
      sourceSelector: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TvFocusable(
              focusNode: _switchFocus,
              onActivate: _chooseSource,
              builder: (context, focused) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xB36D6D6E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: focused ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.swap_horiz_rounded),
                    const SizedBox(width: 8),
                    Text(
                      '切换片源（${state.candidates.map((v) => v.siteKey).toSet().length}）',
                      style: AppTypography.body,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '当前片源：${selection.site.name}',
              style: AppTypography.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (state.loading)
              Text(
                '正在加载其它片源 · ${state.completed}/${state.candidates.length}',
                style: AppTypography.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceChoiceDialog extends ConsumerWidget {
  final VideoItem video;
  final String? selected;
  const _SourceChoiceDialog({required this.video, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(aggregateDetailProvider(video));
    final sites = {for (final site in ref.watch(sitesProvider)) site.key: site};
    final best = state.ranked.firstOrNull?.identity;
    final focused =
        selected ??
        state.initialSelection ??
        videoSourceIdentity(state.candidates.firstOrNull ?? video);
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            {
              LogicalKeyboardKey.escape,
              LogicalKeyboardKey.goBack,
              LogicalKeyboardKey.browserBack,
              LogicalKeyboardKey.gameButtonB,
            }.contains(event.logicalKey)) {
          Navigator.pop(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: AppColors.cardBackground,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 680,
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('选择片源', style: AppTypography.headline2),
                const SizedBox(height: 8),
                const Text('默认使用首页片源，可手动切换', style: AppTypography.body),
                const SizedBox(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final candidate in state.candidates)
                          Builder(
                            builder: (context) {
                              final id = videoSourceIdentity(candidate);
                              final resolved = state.resolved
                                  .where((s) => s.identity == id)
                                  .firstOrNull;
                              final checking = state.checking.contains(id);
                              final status = resolved != null
                                  ? '${resolved.playableEpisodes} 集 · 详情 ${(resolved.responseMs / 1000).toStringAsFixed(1)} 秒'
                                  : checking
                                  ? '正在加载…'
                                  : state.failures[id] ?? '确认加载此片源';
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: TvFocusable(
                                  key: ValueKey(id),
                                  debugLabel: 'detail-source-$id',
                                  autofocus: id == focused,
                                  onActivate: () async {
                                    if (checking) return;
                                    if (resolved == null) {
                                      await ref
                                          .read(
                                            aggregateDetailProvider(
                                              video,
                                            ).notifier,
                                          )
                                          .retry(candidate);
                                      if (!context.mounted) return;
                                      final loaded = ref
                                          .read(aggregateDetailProvider(video))
                                          .resolved
                                          .any((s) => s.identity == id);
                                      if (!loaded) return;
                                    }
                                    if (context.mounted) {
                                      Navigator.pop(context, id);
                                    }
                                  },
                                  builder: (context, focus) => Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: id == selected
                                          ? const Color(0xFF341A20)
                                          : AppColors.surface,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: focus
                                            ? Colors.white
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${sites[candidate.siteKey]?.name ?? '片源已移除'}${id == best ? ' · 推荐' : ''}',
                                                style: AppTypography.title,
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                status,
                                                style: AppTypography.body,
                                              ),
                                              if (state.failures.containsKey(
                                                id,
                                              ))
                                                const Text(
                                                  '确认重试',
                                                  style: AppTypography.caption,
                                                ),
                                            ],
                                          ),
                                        ),
                                        if (id == selected)
                                          const Icon(Icons.check_rounded),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TvActionButton.secondary(
                  label: '返回',
                  debugLabel: 'detail-source-close',
                  autofocus: state.candidates.isEmpty,
                  onActivate: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
