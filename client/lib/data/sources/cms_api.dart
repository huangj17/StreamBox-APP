import 'dart:convert';
import 'package:dio/dio.dart';
import '../../core/network/bounded_response.dart';
import '../../core/network/gateway_auth.dart';
import '../../core/network/url_policy.dart';
import '../models/site.dart';
import '../models/category.dart';
import '../models/video_list_result.dart';
import '../models/cms_video_detail.dart';

class PlayResult {
  final String url;
  final Map<String, String> headers;

  const PlayResult({required this.url, this.headers = const {}});
}

/// 苹果 CMS 网络请求层
class CmsApi {
  static const _maxCmsResponseBytes = 10 * 1024 * 1024;
  final Dio _dio;

  CmsApi(this._dio);

  Future<Map<String, dynamic>> _getJson(
    String rawUrl, {
    Map<String, dynamic>? queryParameters,
    Duration sendTimeout = const Duration(seconds: 8),
    Duration receiveTimeout = const Duration(seconds: 8),
    bool gateway = false,
  }) async {
    final url = UrlPolicy.requireCmsApiUrl(rawUrl, allowLoopback: gateway);
    final text = await getBoundedText(
      _dio,
      url.toString(),
      queryParameters: queryParameters,
      headers: gateway ? GatewayAuth.headers : null,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
      maxBytes: _maxCmsResponseBytes,
    );
    return jsonDecode(text) as Map<String, dynamic>;
  }

  /// 获取分类列表
  /// GET {api}?ac=class
  Future<List<Category>> fetchCategories(Site site) async {
    final data = await _getJson(
      site.api,
      queryParameters: {'ac': 'class'},
      gateway: site.isBridge,
    );
    final list = data['class'] as List<dynamic>? ?? [];
    return list
        .map(
          (e) =>
              Category.fromJson(e as Map<String, dynamic>, siteKey: site.key),
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

    final data = await _getJson(
      site.api,
      queryParameters: params,
      gateway: site.isBridge,
    );
    return VideoListResult.fromJson(data, siteKey: site.key);
  }

  /// 获取视频详情
  /// GET {api}?ac=detail&ids={id}
  Future<CmsVideoDetail?> fetchVideoDetail({
    required Site site,
    required String videoId,
  }) async {
    final data = await _getJson(
      site.api,
      queryParameters: {'ac': 'detail', 'ids': videoId},
      gateway: site.isBridge,
    );
    final list = data['list'] as List<dynamic>? ?? [];
    if (list.isEmpty) return null;
    return CmsVideoDetail.fromJson(list[0] as Map<String, dynamic>);
  }

  /// 调用 JAR Bridge 的 playerContent，取得真实播放地址和必须透传的请求头。
  Future<PlayResult> resolvePlayUrl({
    required Site site,
    required String flag,
    required String rawUrl,
  }) async {
    if (!site.isBridge) {
      throw ArgumentError.value(site.api, 'site', 'Site is not a JAR Bridge');
    }
    final data = await _getJson(
      '${site.api}/play',
      queryParameters: {'flag': flag, 'id': rawUrl},
      receiveTimeout: const Duration(seconds: 20),
      gateway: true,
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
      throw const FormatException('Bridge 未返回有效播放地址');
    }
    final url = UrlPolicy.requirePlaybackUrl(rawResolvedUrl).toString();
    final rawHeaders = data['header'];
    final headers = rawHeaders is Map
        ? rawHeaders.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : const <String, String>{};
    return PlayResult(url: url, headers: headers);
  }

  /// 搜索
  /// GET {api}?wd={keyword}
  Future<VideoListResult> search({
    required Site site,
    required String keyword,
  }) async {
    final data = await _getJson(
      site.api,
      queryParameters: {'wd': keyword},
      gateway: site.isBridge,
    );
    return VideoListResult.fromJson(data, siteKey: site.key);
  }
}
