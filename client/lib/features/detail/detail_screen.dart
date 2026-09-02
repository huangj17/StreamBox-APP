import 'dart:io' show InternetAddress;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/image/image_cache_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/models/site.dart';
import '../../data/models/cms_video_detail.dart';
import '../../data/models/episode.dart';
import '../../data/models/favorite_item.dart';
import '../../widgets/letter_poster.dart';
import '../../widgets/resolvable_cover.dart';
import '../../widgets/tv_back_button.dart';
import '../../widgets/tv_button.dart';
import '../../widgets/tv_focus.dart';
import '../home/providers/categories_provider.dart';
import 'providers/detail_provider.dart';

/// Netflix 风格详情页
class DetailScreen extends ConsumerWidget {
  final Site site;
  final String videoId;

  /// 来自「继续观看」的历史线路索引（可选）
  final int? initialGroupIndex;

  /// 来自「继续观看」的历史集数索引，用于续播定位（可选）
  final int? initialEpisodeIndex;

  /// 来自「继续观看」的历史播放位置（毫秒），用于续播定位（可选）
  final int? initialPositionMs;

  const DetailScreen({
    super.key,
    required this.site,
    required this.videoId,
    this.initialGroupIndex,
    this.initialEpisodeIndex,
    this.initialPositionMs,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(
      videoDetailProvider((site: site, videoId: videoId)),
    );

    return Scaffold(
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Stack(
          children: [
            const Positioned(top: 44, left: 8, child: TvBackButton()),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '加载失败: ${e.toString().contains('500') ? '该片源暂不支持此视频' : e}',
                    style: AppTypography.body,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TvActionButton.secondary(
                    icon: Icons.refresh,
                    label: '重试',
                    autofocus: true,
                    debugLabel: 'detail-error-retry',
                    onActivate: () => ref.invalidate(
                      videoDetailProvider((site: site, videoId: videoId)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        data: (vod) {
          if (vod == null) {
            return const Center(child: Text('未找到'));
          }
          return _DetailContent(
            site: site,
            vod: vod,
            initialGroupIndex: initialGroupIndex,
            initialEpisodeIndex: initialEpisodeIndex,
            initialPositionMs: initialPositionMs,
          );
        },
      ),
    );
  }
}

class _DetailContent extends ConsumerStatefulWidget {
  final Site site;
  final CmsVideoDetail vod;
  final int? initialGroupIndex;
  final int? initialEpisodeIndex;
  final int? initialPositionMs;

  const _DetailContent({
    required this.site,
    required this.vod,
    this.initialGroupIndex,
    this.initialEpisodeIndex,
    this.initialPositionMs,
  });

  @override
  ConsumerState<_DetailContent> createState() => _DetailContentState();
}

class _DetailContentState extends ConsumerState<_DetailContent> {
  late bool _isFavorited;
  int? _resumeGroupIndex;
  int? _resumeEpisodeIndex;
  int? _resumePositionMs;
  bool _warmed = false;

  @override
  void initState() {
    super.initState();
    final storage = ref.read(favoriteStorageProvider);
    _isFavorited = storage.isFavorited(
      widget.vod.vodId.toString(),
      widget.site.key,
    );

    // 如果外部没传历史信息，自动从历史记录中查找
    if (widget.initialGroupIndex == null) {
      final historyStorage = ref.read(historyStorageProvider);
      final allHistory = historyStorage.getAllUnfiltered();
      final videoId = widget.vod.vodId.toString();
      final siteKey = widget.site.key;
      final history = allHistory.where(
        (h) => h.videoId == videoId && h.siteKey == siteKey,
      );
      if (history.isNotEmpty) {
        final h = history.first;
        _resumeGroupIndex = h.groupIndex;
        _resumeEpisodeIndex = h.episodeIndex;
        _resumePositionMs = h.positionMs;
      }
    }

    // 预热播放 URL 的 DNS，节省 libmpv 起播时的解析时间
    _warmPlaybackUrl();
  }

  /// 对"用户最可能播放的那一集"做 DNS 预解析，提前填充系统 DNS 缓存。
  ///
  /// 旧实现用 `dio.head` — 部分站点签发的链接是单次有效 token，HEAD 会
  /// 提前消耗 token 导致 libmpv GET 拿不到流。改成纯 DNS lookup：零副作用
  /// （不发任何 HTTP 请求），节省 50–200ms 解析时间。
  ///
  /// fire-and-forget：失败（无网/host 无效/超时）均静默。
  Future<void> _warmPlaybackUrl() async {
    if (_warmed) return;
    _warmed = true;
    try {
      final gi = _effectiveGroupIndex ?? 0;
      final ei = _effectiveEpisodeIndex ?? 0;
      final groups = widget.vod.episodeGroups;
      if (gi >= groups.length) return;
      if (ei >= groups[gi].length) return;
      final url = groups[gi][ei].url;
      if (url.isEmpty || !url.startsWith('http')) return;
      final host = Uri.tryParse(url)?.host;
      if (host == null || host.isEmpty) return;
      await InternetAddress.lookup(host).timeout(const Duration(seconds: 2));
    } catch (_) {
      // 预热失败（DNS 超时 / 无网）均静默
    }
  }

  int? get _effectiveGroupIndex =>
      widget.initialGroupIndex ?? _resumeGroupIndex;
  int? get _effectiveEpisodeIndex =>
      widget.initialEpisodeIndex ?? _resumeEpisodeIndex;
  int? get _effectivePositionMs =>
      widget.initialPositionMs ?? _resumePositionMs;

  void _toggleFavorite() {
    final storage = ref.read(favoriteStorageProvider);
    final videoId = widget.vod.vodId.toString();
    final siteKey = widget.site.key;

    if (_isFavorited) {
      storage.remove('${videoId}_$siteKey');
    } else {
      storage.add(
        FavoriteItem(
          videoId: videoId,
          siteKey: siteKey,
          title: widget.vod.vodName,
          cover: widget.vod.vodPic,
          year: widget.vod.vodYear,
          category: widget.vod.vodClass,
          remarks: widget.vod.vodRemarks,
          createdAt: DateTime.now(),
        ),
      );
    }

    setState(() => _isFavorited = !_isFavorited);
    ref.invalidate(favoritesProvider);
  }

  void _showEpisodeOptions(
    BuildContext context, {
    required Episode ep,
    required List<List<Episode>> groups,
    required List<String> sourceNames,
    required int groupIndex,
    required int episodeIndex,
  }) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogCtx) {
        return Dialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.xs,
                    ),
                    child: Text(
                      ep.name,
                      style: AppTypography.headline2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _MenuRow(
                    icon: Icons.replay,
                    label: '从头播放',
                    autofocus: true,
                    debugLabel: 'episode-menu-restart',
                    onActivate: () {
                      Navigator.of(dialogCtx).pop();
                      _openPlayer(
                        context,
                        groups: groups,
                        sourceNames: sourceNames,
                        groupIndex: groupIndex,
                        episodeIndex: episodeIndex,
                        positionMs: 0,
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  _MenuRow(
                    icon: Icons.link,
                    label: '复制链接',
                    debugLabel: 'episode-menu-copy',
                    onActivate: () async {
                      await Clipboard.setData(ClipboardData(text: ep.url));
                      if (!dialogCtx.mounted) return;
                      Navigator.of(dialogCtx).pop();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('链接已复制'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openPlayer(
    BuildContext context, {
    required List<List<Episode>> groups,
    required List<String> sourceNames,
    required int groupIndex,
    required int episodeIndex,
    int positionMs = 0,
  }) async {
    await context.push(
      '/player',
      extra: {
        'videoId': widget.vod.vodId.toString(),
        'site': widget.site,
        'videoTitle': widget.vod.vodName,
        'cover': widget.vod.vodPic,
        'episodeGroups': groups,
        'sourceNames': sourceNames,
        'initialGroupIndex': groupIndex,
        'initialEpisodeIndex': episodeIndex,
        'initialPositionMs': positionMs,
        'category': widget.vod.vodClass,
      },
    );

    // 播放器返回后，刷新历史记录以便下次播放能续播
    if (!mounted) return;
    final historyStorage = ref.read(historyStorageProvider);
    final allHistory = historyStorage.getAllUnfiltered();
    final videoId = widget.vod.vodId.toString();
    final siteKey = widget.site.key;
    final history = allHistory.where(
      (h) => h.videoId == videoId && h.siteKey == siteKey,
    );
    if (history.isNotEmpty) {
      final h = history.first;
      setState(() {
        _resumeGroupIndex = h.groupIndex;
        _resumeEpisodeIndex = h.episodeIndex;
        _resumePositionMs = h.positionMs;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final vod = widget.vod;
    final groups = vod.episodeGroups;
    final sourceNames = vod.sourceNames;
    final isCompactPage = MediaQuery.sizeOf(context).width < 600;
    final pageHPad = isCompactPage ? AppSpacing.md : AppSpacing.xl;

    final coverSeed = '${widget.site.key}:${vod.vodId}';

    return Stack(
      children: [
        // 背景图（模糊）：底层铺一层与字母海报同色系的渐变，图片加载完
        // 再盖上；加载失败或无图时自然显示渐变，不会露出纯灰底
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: LetterPoster.gradientFor(coverSeed),
              ),
            ),
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: CachedNetworkImage(
                imageUrl: vod.vodPic,
                fit: BoxFit.cover,
                memCacheWidth: 512,
                cacheManager: AppImageCacheManager(),
                color: Colors.black54,
                colorBlendMode: BlendMode.darken,
                placeholder: (_, _) => const SizedBox.shrink(),
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        // 底部渐变
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, AppColors.deepBlack],
                stops: [0.3, 0.8],
              ),
            ),
          ),
        ),
        // 内容
        CustomScrollView(
          slivers: [
            // 返回按钮
            SliverToBoxAdapter(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: isCompactPage ? AppSpacing.xs : AppSpacing.md,
                    top: isCompactPage ? AppSpacing.xs : AppSpacing.md,
                    right: AppSpacing.md,
                    bottom: isCompactPage ? AppSpacing.sm : AppSpacing.md,
                  ),
                  child: const Align(
                    alignment: Alignment.topLeft,
                    child: TvBackButton(),
                  ),
                ),
              ),
            ),

            // 影片信息区
            SliverToBoxAdapter(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 600;
                  final hPad = isCompact ? AppSpacing.md : AppSpacing.xl;
                  final posterW = isCompact ? 100.0 : 200.0;
                  final posterH = isCompact ? 150.0 : 300.0;
                  final gap = isCompact ? AppSpacing.sm : AppSpacing.lg;

                  final hasPlay =
                      groups.isNotEmpty &&
                      groups[0].isNotEmpty &&
                      groups[0][0].url.isNotEmpty;

                  final resumeMs = _effectivePositionMs ?? 0;
                  final hasResume = hasPlay && resumeMs > 0;
                  final isSeries = groups.any((g) => g.length > 1);
                  final resumeGi = hasPlay
                      ? (_effectiveGroupIndex ?? 0).clamp(0, groups.length - 1)
                      : 0;
                  final resumeEi = hasPlay
                      ? (_effectiveEpisodeIndex ?? 0).clamp(
                          0,
                          groups[resumeGi].length - 1,
                        )
                      : 0;
                  final playLabel = hasResume
                      ? (isSeries
                            ? '继续 ${groups[resumeGi][resumeEi].name} '
                                  '${_formatHms(resumeMs)}'
                            : '继续观看 ${_formatHms(resumeMs)}')
                      : '播放';

                  final actions = <Widget>[
                    if (hasPlay)
                      TvActionButton.primary(
                        icon: Icons.play_arrow,
                        label: playLabel,
                        compact: isCompact,
                        autofocus: true,
                        debugLabel: 'detail-play',
                        onActivate: () => _openPlayer(
                          context,
                          groups: groups,
                          sourceNames: sourceNames,
                          groupIndex: resumeGi,
                          episodeIndex: resumeEi,
                          positionMs: resumeMs,
                        ),
                      ),
                    if (hasResume)
                      TvActionButton.secondary(
                        icon: Icons.replay,
                        label: '从头播放',
                        compact: isCompact,
                        debugLabel: 'detail-restart',
                        onActivate: () => _openPlayer(
                          context,
                          groups: groups,
                          sourceNames: sourceNames,
                          groupIndex: resumeGi,
                          episodeIndex: resumeEi,
                          positionMs: 0,
                        ),
                      ),
                    _isFavorited
                        ? TvActionButton.red(
                            icon: Icons.check,
                            label: '已收藏',
                            compact: isCompact,
                            autofocus: !hasPlay,
                            debugLabel: 'detail-favorite',
                            onActivate: _toggleFavorite,
                          )
                        : TvActionButton.secondary(
                            icon: Icons.add,
                            label: '收藏',
                            compact: isCompact,
                            autofocus: !hasPlay,
                            debugLabel: 'detail-favorite',
                            onActivate: _toggleFavorite,
                          ),
                  ];

                  final poster = ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: posterW,
                      height: posterH,
                      child: ResolvableCover(
                        directUrl: vod.vodPic,
                        title: vod.vodName,
                        year: vod.vodYear,
                        seed: coverSeed,
                        fit: BoxFit.cover,
                        memCacheWidth: 400,
                        letterScale: 0.4,
                      ),
                    ),
                  );

                  final title = Text(
                    vod.vodName,
                    style: isCompact
                        ? AppTypography.title.copyWith(
                            fontWeight: FontWeight.bold,
                            height: 1.25,
                          )
                        : AppTypography.headline1,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  );

                  final metaChips = Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      _MetaChip('片源：${widget.site.name}'),
                      if (vod.vodYear?.isNotEmpty == true)
                        _MetaChip(vod.vodYear!),
                      if (vod.vodArea?.isNotEmpty == true)
                        _MetaChip(vod.vodArea!),
                      if (vod.vodClass?.isNotEmpty == true)
                        _MetaChip(vod.vodClass!),
                      if (vod.vodLang?.isNotEmpty == true)
                        _MetaChip(vod.vodLang!),
                      if (vod.vodRemarks?.isNotEmpty == true)
                        _MetaChip(vod.vodRemarks!),
                      if (_hasScore(vod.vodDoubanScore))
                        _MetaChip('豆瓣 ${vod.vodDoubanScore}', highlight: true),
                      if (!_hasScore(vod.vodDoubanScore) &&
                          _hasScore(vod.vodScore))
                        _MetaChip('评分 ${vod.vodScore}', highlight: true),
                    ],
                  );

                  final director = (vod.vodDirector?.isNotEmpty == true)
                      ? Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.sm),
                          child: Text(
                            '导演：${vod.vodDirector}',
                            style: AppTypography.caption.copyWith(
                              color: AppColors.secondaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      : null;
                  final actor = (vod.vodActor?.isNotEmpty == true)
                      ? Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Text(
                            '演员：${vod.vodActor}',
                            style: AppTypography.caption.copyWith(
                              color: AppColors.secondaryText,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      : null;
                  final intro = vod.vodContent.isNotEmpty
                      ? Text(
                          vod.vodContent,
                          style: AppTypography.body,
                          maxLines: isCompact ? 6 : 4,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null;

                  if (isCompact) {
                    // 手机端：海报 + 标题/标签 上下并列；简介、演职员、按钮 全宽
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: hPad),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              poster,
                              SizedBox(width: gap),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    title,
                                    const SizedBox(height: AppSpacing.xs),
                                    metaChips,
                                  ],
                                ),
                              ),
                            ],
                          ),
                          ?director,
                          ?actor,
                          if (intro != null) ...[
                            const SizedBox(height: AppSpacing.md),
                            intro,
                            if (vod.vodContent.length > 80) ...[
                              const SizedBox(height: AppSpacing.xs),
                              _ExpandIntroButton(
                                title: vod.vodName,
                                content: vod.vodContent,
                              ),
                            ],
                          ],
                          const SizedBox(height: AppSpacing.lg),
                          Wrap(
                            spacing: AppSpacing.md,
                            runSpacing: AppSpacing.sm,
                            children: actions,
                          ),
                        ],
                      ),
                    );
                  }

                  // 平板/桌面：保持左右两栏布局
                  return Padding(
                    padding: EdgeInsets.symmetric(horizontal: hPad),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        poster,
                        SizedBox(width: gap),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: AppSpacing.md),
                              title,
                              const SizedBox(height: AppSpacing.sm),
                              metaChips,
                              ?director,
                              ?actor,
                              if (intro != null) ...[
                                const SizedBox(height: AppSpacing.md),
                                intro,
                                if (vod.vodContent.length > 80) ...[
                                  const SizedBox(height: AppSpacing.xs),
                                  _ExpandIntroButton(
                                    title: vod.vodName,
                                    content: vod.vodContent,
                                  ),
                                ],
                              ],
                              const SizedBox(height: AppSpacing.lg),
                              Wrap(
                                spacing: AppSpacing.md,
                                runSpacing: AppSpacing.sm,
                                children: actions,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),

            // 剧集分组
            for (var i = 0; i < groups.length; i++) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: pageHPad,
                    top: AppSpacing.md,
                    bottom: AppSpacing.sm,
                  ),
                  child: Text(
                    sourceNames.length > i ? sourceNames[i] : '线路 ${i + 1}',
                    style: AppTypography.headline2,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 48,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: pageHPad),
                    itemCount: groups[i].length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: AppSpacing.sm),
                    itemBuilder: (context, j) {
                      final ep = groups[i][j];
                      final disabled = ep.url.isEmpty;
                      return Center(
                        child: _EpisodeChip(
                          label: ep.name,
                          disabled: disabled,
                          debugLabel: 'episode-$i-$j',
                          onActivate: disabled
                              ? null
                              : () => _openPlayer(
                                  context,
                                  groups: groups,
                                  sourceNames: sourceNames,
                                  groupIndex: i,
                                  episodeIndex: j,
                                ),
                          onLongActivate: disabled
                              ? null
                              : () => _showEpisodeOptions(
                                  context,
                                  ep: ep,
                                  groups: groups,
                                  sourceNames: sourceNames,
                                  groupIndex: i,
                                  episodeIndex: j,
                                ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
          ],
        ),
      ],
    );
  }
}

/// 详情页弹窗中的菜单行（TV 焦点：红环+光晕；选中态由调用方表达）
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool autofocus;
  final String? debugLabel;
  final VoidCallback onActivate;

  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onActivate,
    this.autofocus = false,
    this.debugLabel,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: debugLabel,
      autofocus: autofocus,
      onActivate: onActivate,
      ensureVisibleOnFocus: false,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: focused ? AppColors.netflixRed : Colors.transparent,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.primaryText),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  label,
                  style: AppTypography.body.copyWith(
                    color: AppColors.primaryText,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 详情页"展开简介"按钮（TV 焦点：红环+光晕）
class _ExpandIntroButton extends StatelessWidget {
  final String title;
  final String content;

  const _ExpandIntroButton({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TvFocusable(
        debugLabel: 'detail-expand-intro',
        ensureVisibleOnFocus: false,
        onActivate: () => _showIntroDialog(context),
        builder: (context, focused) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: focused ? AppColors.netflixRed : Colors.transparent,
                width: 1,
              ),
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: AppColors.netflixRed.withAlpha(100),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '展开',
                  style: AppTypography.caption.copyWith(
                    color: focused
                        ? AppColors.netflixRed
                        : AppColors.secondaryText,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: focused
                      ? AppColors.netflixRed
                      : AppColors.secondaryText,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showIntroDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogCtx) {
        return Dialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTypography.headline2),
                  const SizedBox(height: AppSpacing.md),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Text(content, style: AppTypography.body),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _MenuRow(
                      icon: Icons.close,
                      label: '关闭',
                      autofocus: true,
                      debugLabel: 'intro-dialog-close',
                      onActivate: () => Navigator.of(dialogCtx).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 详情页集数 chip（TV 焦点：红环+光晕，圆角 19）
class _EpisodeChip extends StatelessWidget {
  final String label;
  final bool disabled;
  final String? debugLabel;
  final VoidCallback? onActivate;
  final VoidCallback? onLongActivate;

  const _EpisodeChip({
    required this.label,
    required this.disabled,
    required this.onActivate,
    this.onLongActivate,
    this.debugLabel,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      debugLabel: debugLabel,
      onActivate: onActivate,
      onLongActivate: onLongActivate,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: focused ? AppColors.netflixRed : AppColors.divider,
              width: 1,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.netflixRed.withAlpha(100),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: AppTypography.caption.copyWith(
              color: disabled ? AppColors.hintText : AppColors.primaryText,
            ),
          ),
        );
      },
    );
  }
}

/// 评分是否有效（非空、非 0、非 0.0）
bool _hasScore(String? score) {
  if (score == null || score.isEmpty) return false;
  final v = double.tryParse(score);
  return v != null && v > 0;
}

/// 毫秒 → "h:mm:ss" 或 "m:ss"
String _formatHms(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(sec)}';
  return '$m:${two(sec)}';
}

/// 元数据标签
class _MetaChip extends StatelessWidget {
  final String label;
  final bool highlight;

  const _MetaChip(this.label, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: highlight
            ? AppColors.netflixRed.withAlpha(40)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(4),
        border: highlight
            ? Border.all(color: AppColors.netflixRed.withAlpha(100))
            : null,
      ),
      child: Text(
        label,
        style: AppTypography.caption.copyWith(
          color: highlight ? AppColors.netflixRed : AppColors.secondaryText,
          fontSize: 12,
        ),
      ),
    );
  }
}
