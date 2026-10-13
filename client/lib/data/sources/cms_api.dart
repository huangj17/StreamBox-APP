import 'dart:convert';
import 'package:dio/dio.dart';
import '../../core/network/bounded_response.dart';
import '../../core/network/url_policy.dart';
import 'cms_xml_decoder.dart';
import 'android_spider_client.dart';
import '../models/site.dart';
import '../models/category.dart';
import '../models/video_list_result.dart';
import '../models/cms_video_detail.dart';

class PlayResult {
  final String url;
  final Map<String, String> headers;

  const PlayResult({required this.url, this.headers = const {}});
}

/// Unified data facade: portable CMS HTTP or Android-local Spider calls.
class CmsApi {
  static const _maxCmsResponseBytes = 10 * 1024 * 1024;
  final Dio _dio;

  final AndroidSpiderClient _spider;

  CmsApi(this._dio, {AndroidSpiderClient? spider})
    : _spider = spider ?? AndroidSpiderClient();

  Future<Map<String, dynamic>> _getJson(
    Site site, {
    Map<String, dynamic>? queryParameters,
    Duration sendTimeout = const Duration(seconds: 8),
    Duration receiveTimeout = const Duration(seconds: 8),
    CancelToken? cancelToken,
  }) async {
    if (site.retiredBridge) throw const FormatException('旧 JAR Bridge 已停用');
    if (site.isJar) {
      if (!site.isSupported) {
        throw const FormatException('该 JAR 片源仅支持 Android 设备');
      }
      final q = queryParameters ?? const <String, dynamic>{};
      final String method;
      final Map<String, dynamic> params;
      if (q.containsKey('wd')) {
        method = 'search';
        params = {'keyword': q['wd'], 'quick': false};
      } else if (q.containsKey('ids')) {
        method = 'detail';
        params = {
          'ids': [q['ids'].toString()],
        };
      } else if (q.containsKey('t')) {
        method = 'category';
        params = {
          'tid': q['t'].toString(),
          'page': (q['pg'] ?? 1).toString(),
          'filter': true,
          'extend': {if (q['year'] != null) 'year': q['year']},
        };
      } else {
        method = 'home';
        params = {'filter': true};
      }
      return _spider.invoke(
        site,
        method,
        params: params,
        cancelToken: cancelToken,
      );
    }
    final url = UrlPolicy.requireCmsApiUrl(site.api);
    final text = await getBoundedText(
      _dio,
      url.toString(),
      queryParameters: queryParameters,
      headers: site.headers,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
      cancelToken: cancelToken,
      maxBytes: _maxCmsResponseBytes,
    );
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('<')) return decodeCmsXml(text);
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('CMS 响应必须是 JSON 对象或 XML 文档');
    }
    return decoded;
  }

  /// 获取分类列表
  /// GET {api}?ac=class
  Future<List<Category>> fetchCategories(
    Site site, {
    CancelToken? cancelToken,
  }) async {
    final data = await _getJson(
      site,
      queryParameters: {'ac': 'class'},
      cancelToken: cancelToken,
    );
    final list = data['class'] is List ? data['class'] as List : const [];
    return list
        .whereType<Map>()
        .map(
          (e) => Category.fromJson(
            Map<String, dynamic>.from(e),
            siteKey: site.key,
          ),
        )
        .toList();
  }

  /// 获取分类内容列表
  /// GET {api}?ac=detail&t={categoryId}&pg={page}[&year={year}]
  Future<VideoListResult> fetchVideoList({
    required Site site,
    required String categoryId,
    int page = 1,
    String? year,
  }) async {
    final params = <String, dynamic>{
      'ac': 'detail',
      't': categoryId,
      'pg': page,
    };
    if (year != null && year.isNotEmpty) params['year'] = year;

    final data = await _getJson(site, queryParameters: params);
    return VideoListResult.fromJson(data, siteKey: site.key);
  }

  /// 获取视频详情
  /// GET {api}?ac=detail&ids={id}
  Future<CmsVideoDetail?> fetchVideoDetail({
    required Site site,
    required String videoId,
  }) async {
    final data = await _getJson(
      site,
      queryParameters: {'ac': 'detail', 'ids': videoId},
    );
    final list = data['list'] is List ? data['list'] as List : const [];
    if (list.isEmpty) return null;
    final first = list.first;
    if (first is! Map) return null;
    return CmsVideoDetail.fromJson(
      Map<String, dynamic>.from(first),
      isJar: site.isJar,
    );
  }

  /// Resolve every Android plugin episode, even if its ID looks like an HTTP URL.
  Future<PlayResult> resolvePlayUrl({
    required Site site,
    required String flag,
    required String rawUrl,
  }) async {
    if (!site.isSupported) {
      throw const FormatException('该 JAR 片源仅支持 Android 设备');
    }
    if (!site.isJar) {
      throw ArgumentError.value(site.api, 'site', 'Not an Android JAR source');
    }
    final data = await _spider.invoke(
      site,
      'play',
      params: {'flag': flag, 'id': rawUrl},
    );
    final parse = switch (data['parse']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value) ?? 0,
      _ => 0,
    };
    if (parse != 0) {
      throw const FormatException('该线路仍需要网页解析，当前播放器无法直接播放');
    }
    final rawResolvedUrl = data['url']?.toString().trim() ?? '';
    if (rawResolvedUrl.isEmpty) {
      throw const FormatException('插件未返回有效播放地址');
    }
    final url = UrlPolicy.requirePlaybackUrl(rawResolvedUrl).toString();
    final header = data['header'];
    final rawHeaders = header is String && header.trim().isNotEmpty
        ? jsonDecode(header)
        : header;
    final headers = rawHeaders is Map
        ? rawHeaders.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : const <String, String>{};
    return PlayResult(
      url: url,
      headers: headers.isEmpty ? site.headers : headers,
    );
  }

  /// 搜索
  /// GET {api}?wd={keyword}
  Future<VideoListResult> search({
    required Site site,
    required String keyword,
    CancelToken? cancelToken,
  }) async {
    final data = await _getJson(
      site,
      queryParameters: {'wd': keyword},
      cancelToken: cancelToken,
    );
    return VideoListResult.fromJson(data, siteKey: site.key);
  }
}
