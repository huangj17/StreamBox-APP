import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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
    final detail =
        ref.watch(videoDetailProvider((site: site, videoId: videoId)));

    return Scaffold(
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Stack(
          children: [
            const Positioned(
              top: 44,
              left: 8,
              child: BackButton(color: Colors.white),
            ),
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
                  ElevatedButton(
                    onPressed: () => ref.invalidate(
                        videoDetailProvider((site: site, videoId: videoId))),
                    child: const Text('重试'),
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

    // 预热播放 URL 的 DNS/TCP/TLS，用户点击播放时 libmpv 直接复用
    _warmPlaybackUrl();
  }

  /// 对"用户最可能播放的那一集" 做一次 HEAD，预热连接。
  ///
  /// fire-and-forget：任何失败（405/超时/连不上）都静默，不影响详情页。
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
      final dio = ref.read(dioProvider);
      await dio.head<dynamic>(
        url,
        options: Options(
          receiveTimeout: const Duration(seconds: 3),
          sendTimeout: const Duration(seconds: 3),
          followRedirects: true,
        ),
      );
    } catch (_) {
      // 预热失败（405/416/超时/SSL）均静默
    }
  }

  int? get _effectiveGroupIndex => widget.initialGroupIndex ?? _resumeGroupIndex;
  int? get _effectiveEpisodeIndex => widget.initialEpisodeIndex ?? _resumeEpisodeIndex;
  int? get _effectivePositionMs => widget.initialPositionMs ?? _resumePositionMs;

  void _toggleFavorite() {
    final storage = ref.read(favoriteStorageProvider);
    final videoId = widget.vod.vodId.toString();
    final siteKey = widget.site.key;

    if (_isFavorited) {
      storage.remove('${videoId}_$siteKey');
    } else {
      storage.add(FavoriteItem(
        videoId: videoId,
        siteKey: siteKey,
        title: widget.vod.vodName,
        cover: widget.vod.vodPic,
        year: widget.vod.vodYear,
        category: widget.vod.vodClass,
        remarks: widget.vod.vodRemarks,
        createdAt: DateTime.now(),
      ));
    }

    setState(() => _isFavorited = !_isFavorited);
    ref.invalidate(favoritesProvider);
  }

  Future<void> _openPlayer(
    BuildContext context, {
    required List<List<Episode>> groups,
    required List<String> sourceNames,
    required int groupIndex,
    required int episodeIndex,
    int positionMs = 0,
  }) async {
    await context.push('/player', extra: {
      'videoId': widget.vod.vodId.toString(),
      'siteKey': widget.site.key,
      'videoTitle': widget.vod.vodName,
      'cover': widget.vod.vodPic,
      'episodeGroups': groups,
      'sourceNames': sourceNames,
      'initialGroupIndex': groupIndex,
      'initialEpisodeIndex': episodeIndex,
      'initialPositionMs': positionMs,
      'category': widget.vod.vodClass,
    });

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
    final isCompactPage =
        MediaQuery.sizeOf(context).width < 600;
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
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: AppColors.primaryText),
                      onPressed: () => context.pop(),
                    ),
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

                  final hasPlay = groups.isNotEmpty &&
                      groups[0].isNotEmpty &&
                      groups[0][0].url.isNotEmpty;

                  // 手机端按钮紧凑样式
                  final compactBtnStyle = isCompact
                      ? ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                          ),
                          textStyle: const TextStyle(fontSize: 14),
                        )
                      : null;

                  final actions = <Widget>[
                    if (hasPlay)
                      ElevatedButton.icon(
                        onPressed: () {
                          final gi = (_effectiveGroupIndex ?? 0)
                              .clamp(0, groups.length - 1);
                          final ep = (_effectiveEpisodeIndex ?? 0)
                              .clamp(0, groups[gi].length - 1);
                          _openPlayer(
                            context,
                            groups: groups,
                            sourceNames: sourceNames,
                            groupIndex: gi,
                            episodeIndex: ep,
                            positionMs: _effectivePositionMs ?? 0,
                          );
                        },
                        icon: Icon(Icons.play_arrow, size: isCompact ? 18 : 24),
                        label: const Text('播放'),
                        style: compactBtnStyle,
                      ),
                    ElevatedButton.icon(
                      onPressed: _toggleFavorite,
                      icon: Icon(
                        _isFavorited ? Icons.check : Icons.add,
                        size: isCompact ? 18 : 24,
                      ),
                      label: Text(_isFavorited ? '已收藏' : '收藏'),
                      style: (compactBtnStyle ?? const ButtonStyle()).copyWith(
                        backgroundColor: WidgetStatePropertyAll(
                          _isFavorited
                              ? AppColors.netflixRed.withAlpha(178)
                              : const Color(0xB36D6D6E),
                        ),
                        foregroundColor: const WidgetStatePropertyAll(
                          AppColors.primaryText,
                        ),
                      ),
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
                        _MetaChip('豆瓣 ${vod.vodDoubanScore}',
                            highlight: true),
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
                            style: AppTypography.caption
                                .copyWith(color: AppColors.secondaryText),
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
                            style: AppTypography.caption
                                .copyWith(color: AppColors.secondaryText),
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
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
            const SliverToBoxAdapter(
                child: SizedBox(height: AppSpacing.lg)),

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
                    sourceNames.length > i
                        ? sourceNames[i]
                        : '线路 ${i + 1}',
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
                      return ActionChip(
                        label: Text(ep.name),
                        backgroundColor: AppColors.surface,
                        onPressed: ep.url.isEmpty
                            ? null
                            : () => _openPlayer(
                                  context,
                                  groups: groups,
                                  sourceNames: sourceNames,
                                  groupIndex: i,
                                  episodeIndex: j,
                                ),
                      );
                    },
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(
                child: SizedBox(height: AppSpacing.xxl)),
          ],
        ),
      ],
    );
  }
}

/// 评分是否有效（非空、非 0、非 0.0）
bool _hasScore(String? score) {
  if (score == null || score.isEmpty) return false;
  final v = double.tryParse(score);
  return v != null && v > 0;
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
