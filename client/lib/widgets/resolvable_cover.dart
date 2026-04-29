import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/image/image_cache_manager.dart';
import '../data/cover/cover_resolver.dart';
import '../data/cover/providers.dart';
import 'letter_poster.dart';

/// 统一的封面渲染入口。回退链：
///   直链非空 → 显示直链（加载失败回退字母海报）
///   直链为空 → 触发第三方查询（TMDB/豆瓣），期间字母海报兜底
///              查询命中 → 显示解析出的 URL（豆瓣图自动带 Referer）
///              查询未命中 → 字母海报常驻
class ResolvableCover extends ConsumerStatefulWidget {
  final String? directUrl;
  final String title;
  final String? year;
  final String seed;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final double letterScale;
  final Widget Function(BuildContext, ImageProvider)? imageBuilder;
  final Color? color;
  final BlendMode? colorBlendMode;
  /// 自定义失败/加载态展示。不传则用 LetterPoster。
  /// 传 SizedBox.shrink() 可在失败时完全不渲染。
  final Widget? fallback;

  const ResolvableCover({
    super.key,
    required this.directUrl,
    required this.title,
    this.year,
    required this.seed,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.memCacheWidth,
    this.letterScale = 0.45,
    this.imageBuilder,
    this.color,
    this.colorBlendMode,
    this.fallback,
  });

  @override
  ConsumerState<ResolvableCover> createState() => _ResolvableCoverState();
}

class _ResolvableCoverState extends ConsumerState<ResolvableCover> {
  ResolvedCover? _resolved;
  bool _resolving = false;
  bool _directFailed = false;
  int _cacheVersion = 0;

  bool get _directEmpty => (widget.directUrl?.trim() ?? '').isEmpty;

  @override
  void initState() {
    super.initState();
    _cacheVersion = ref.read(coverCacheVersionProvider);
    if (_directEmpty) _kickOffResolve();
  }

  @override
  void didUpdateWidget(covariant ResolvableCover old) {
    super.didUpdateWidget(old);
    if (old.directUrl != widget.directUrl ||
        old.title != widget.title ||
        old.year != widget.year) {
      _resolved = null;
      _resolving = false;
      _directFailed = false;
      if (_directEmpty) _kickOffResolve();
    }
  }

  /// 直链加载失败时延迟到下一帧触发 resolve（不能在 build 里 setState）
  void _onDirectFailed() {
    if (_directFailed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _directFailed) return;
      setState(() => _directFailed = true);
      _kickOffResolve();
    });
  }

  void _kickOffResolve() {
    if (_resolving || _resolved != null) return;
    if (widget.title.trim().isEmpty) return;
    _resolving = true;
    final resolver = ref.read(coverResolverProvider);
    resolver.resolve(widget.title, widget.year).then((r) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _resolved = r;
      });
    }).catchError((_) {
      if (mounted) setState(() => _resolving = false);
    });
  }

  Widget _buildFallback() {
    if (widget.fallback != null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: widget.fallback,
      );
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: LetterPoster(
        title: widget.title,
        seed: widget.seed,
        letterScale: widget.letterScale,
      ),
    );
  }

  Widget _buildImage(
    String url, {
    Map<String, String>? httpHeaders,
    bool triggerResolveOnError = false,
  }) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      memCacheWidth: widget.memCacheWidth,
      cacheManager: AppImageCacheManager(),
      color: widget.color,
      colorBlendMode: widget.colorBlendMode,
      imageBuilder: widget.imageBuilder,
      httpHeaders: httpHeaders,
      placeholder: (_, _) => _buildFallback(),
      errorWidget: (_, _, _) {
        if (triggerResolveOnError) _onDirectFailed();
        return _buildFallback();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 缓存版本号变了（用户刚清掉 miss）→ 重置并重试
    final version = ref.watch(coverCacheVersionProvider);
    if (version != _cacheVersion) {
      _cacheVersion = version;
      _resolved = null;
      _resolving = false;
      _directFailed = false;
      if (_directEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _kickOffResolve();
        });
      }
    }

    if (_resolved != null) {
      return _buildImage(_resolved!.url, httpHeaders: _resolved!.httpHeaders);
    }
    final direct = widget.directUrl?.trim() ?? '';
    // 直链未失败前优先尝试它；失败后就直接走字母海报 + 等 resolve 结果
    if (direct.isNotEmpty && !_directFailed) {
      return _buildImage(direct, triggerResolveOnError: true);
    }
    return _buildFallback();
  }
}
