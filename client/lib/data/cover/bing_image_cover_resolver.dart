import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'cover_resolver.dart';

/// Bing 图片搜索：用 `cn.bing.com` 国内可直连。作为豆瓣/TMDB 都搜不到时的
/// 兜底，覆盖面最广（冷门短剧、番剧、综艺也常能搜到官方海报或剧照）。
///
/// 质量不如 TMDB/豆瓣稳定：第一张可能是剧照而非海报，偶尔也会是无关图。
/// 但对「有图总比字母海报好」的场景足够。
class BingImageCoverResolver implements CoverResolver {
  static const _endpoint = 'https://cn.bing.com/images/search';
  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36';

  /// Bing HTML 每张图片挂在 `<a class="iusc" m="{...}">`，m 属性里是
  /// HTML-escape 过的 JSON，murl 字段是原图直链
  static final _mAttrRe = RegExp(r'class="iusc"[^>]*m="([^"]+)"');

  final Dio _dio;

  BingImageCoverResolver(this._dio);

  @override
  Future<ResolvedCover?> resolve(String title, String? year) async {
    final q = title.trim();
    if (q.isEmpty) return null;

    try {
      final res = await _dio.get<String>(
        _endpoint,
        queryParameters: {
          // 加「海报」关键词提升相关度
          'q': '$q 海报',
          'form': 'HDRSC2',
          'first': '1',
        },
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
          responseType: ResponseType.plain,
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'text/html,application/xhtml+xml',
          },
        ),
      );
      final html = res.data;
      if (html == null || html.isEmpty) {
        if (kDebugMode) print('[Bing] "$title": empty body');
        return null;
      }

      final match = _mAttrRe.firstMatch(html);
      if (match == null) {
        if (kDebugMode) print('[Bing] "$title": no image blocks');
        return null;
      }
      final jsonStr = match
          .group(1)!
          .replaceAll('&quot;', '"')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>');
      try {
        final data = jsonDecode(jsonStr);
        if (data is Map) {
          final murl = data['murl'];
          if (murl is String && murl.isNotEmpty) {
            if (kDebugMode) print('[Bing] "$title" → $murl');
            return ResolvedCover(murl, 'bing');
          }
        }
      } catch (e) {
        if (kDebugMode) print('[Bing] "$title" json parse: $e');
      }
      return null;
    } on DioException catch (e) {
      if (kDebugMode) {
        print('[Bing] "$title" dio error: ${e.type} ${e.message}');
      }
      return null;
    } catch (e) {
      if (kDebugMode) print('[Bing] "$title" error: $e');
      return null;
    }
  }
}
