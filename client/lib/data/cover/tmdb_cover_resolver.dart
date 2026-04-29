import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'cover_resolver.dart';

/// TMDB 封面查询：https://api.themoviedb.org/3/search/multi
///
/// API key 通过 [_apiKeyGetter] 惰性读取，用户在设置里修改后下次调用自动生效。
/// 未配置 key 或查不到时返回 null，不抛异常。
class TmdbCoverResolver implements CoverResolver {
  static const _endpoint = 'https://api.themoviedb.org/3/search/multi';
  static const _imageBase = 'https://image.tmdb.org/t/p/w500';

  final Dio _dio;
  final String Function() _apiKeyGetter;

  TmdbCoverResolver(this._dio, this._apiKeyGetter);

  @override
  Future<ResolvedCover?> resolve(String title, String? year) async {
    final key = _apiKeyGetter().trim();
    if (key.isEmpty) {
      if (kDebugMode) print('[TMDB] skip "$title": key empty');
      return null;
    }
    final q = title.trim();
    if (q.isEmpty) return null;

    try {
      // 全局 Dio 设了 ResponseType.plain；这里拿原始字符串手动解 JSON，
      // 避免被上游配置影响
      final res = await _dio.get<String>(
        _endpoint,
        queryParameters: {
          'api_key': key,
          'query': q,
          if (year != null && year.trim().isNotEmpty) 'year': year.trim(),
          'language': 'zh-CN',
          'include_adult': 'false',
        },
        options: Options(
          // 国内直连 api.themoviedb.org 常不稳，超时短一点快速 fail 让
          // 后续 resolver 接手，避免每个 miss 都要等 6s
          receiveTimeout: const Duration(seconds: 3),
          sendTimeout: const Duration(seconds: 3),
          responseType: ResponseType.plain,
        ),
      );
      final raw = res.data;
      if (raw == null || raw.isEmpty) {
        if (kDebugMode) print('[TMDB] "$title": empty body');
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final results = decoded['results'];
      if (results is! List) {
        if (kDebugMode) {
          print('[TMDB] "$title": unexpected payload $decoded');
        }
        return null;
      }
      for (final item in results) {
        if (item is! Map) continue;
        final posterPath = item['poster_path'];
        if (posterPath is String && posterPath.isNotEmpty) {
          final url = '$_imageBase$posterPath';
          if (kDebugMode) print('[TMDB] "$title" → $url');
          return ResolvedCover(url, 'tmdb');
        }
      }
      if (kDebugMode) {
        print('[TMDB] "$title": ${results.length} hits but no poster_path');
      }
      return null;
    } on DioException catch (e) {
      if (kDebugMode) {
        print('[TMDB] "$title" dio error: ${e.type} ${e.message}');
      }
      return null;
    } catch (e) {
      if (kDebugMode) print('[TMDB] "$title" error: $e');
      return null;
    }
  }
}
