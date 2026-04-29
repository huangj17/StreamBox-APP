import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'cover_resolver.dart';

/// 豆瓣封面查询：走 movie.douban.com 的 subject_suggest JSON 接口，
/// 无需 API key。国产剧综、短剧的覆盖明显优于 TMDB。
///
/// 说明：
/// - 需要常见浏览器 UA，否则直接 403
/// - 返回的图片 URL 在 doubanio.com 域名下，有 Referer 防盗链。
///   实际渲染时由 [ResolvedCover.httpHeaders] 负责注入 Referer
/// - HTTP 失败 / JSON 解析失败 / 空结果 都返回 null，不抛异常
class DoubanCoverResolver implements CoverResolver {
  static const _suggestEndpoint =
      'https://movie.douban.com/j/subject_suggest';
  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36';

  final Dio _dio;

  DoubanCoverResolver(this._dio);

  @override
  Future<ResolvedCover?> resolve(String title, String? year) async {
    final q = title.trim();
    if (q.isEmpty) return null;

    try {
      final res = await _dio.get<String>(
        _suggestEndpoint,
        queryParameters: {'q': q},
        options: Options(
          receiveTimeout: const Duration(seconds: 6),
          sendTimeout: const Duration(seconds: 6),
          headers: {
            'User-Agent': _userAgent,
            'Referer': 'https://movie.douban.com/',
            'Accept': 'application/json, text/plain, */*',
          },
          // 豆瓣偶尔返回 content-type: text/html 但内容是 JSON
          responseType: ResponseType.plain,
        ),
      );
      final raw = res.data;
      if (raw == null || raw.isEmpty) {
        if (kDebugMode) print('[Douban] "$title": empty body');
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        if (kDebugMode) {
          print('[Douban] "$title": unexpected payload $decoded');
        }
        return null;
      }

      // 优先返回标题精确匹配 + 年份匹配的，其次返回首个有图的
      Map<String, dynamic>? fallback;
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final m = Map<String, dynamic>.from(entry);
        final img = m['img'];
        if (img is! String || img.isEmpty) continue;
        fallback ??= m;
        final titleMatch = (m['title'] as String?)?.trim() == q;
        final yMatch = year == null ||
            year.trim().isEmpty ||
            (m['year'] as String?)?.trim() == year.trim();
        if (titleMatch && yMatch) {
          if (kDebugMode) print('[Douban] "$title" → $img (exact)');
          return ResolvedCover(img, 'douban');
        }
      }
      if (fallback != null) {
        final img = fallback['img'] as String;
        if (kDebugMode) print('[Douban] "$title" → $img (fallback)');
        return ResolvedCover(img, 'douban');
      }
      if (kDebugMode) print('[Douban] "$title": 0 hits');
      return null;
    } on DioException catch (e) {
      if (kDebugMode) {
        print('[Douban] "$title" dio error: ${e.type} ${e.message}');
      }
      return null;
    } catch (e) {
      if (kDebugMode) print('[Douban] "$title" error: $e');
      return null;
    }
  }
}
