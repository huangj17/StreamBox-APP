import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/site.dart';
import '../models/category.dart';
import '../models/video_list_result.dart';
import '../models/cms_video_detail.dart';

/// 苹果 CMS 网络请求层
class CmsApi {
  final Dio _dio;

  CmsApi(this._dio);

  Map<String, dynamic> _decode(Response response) {
    // 部分 CMS 返回 text/html content-type，需手动解码
    if (response.data is String) {
      return jsonDecode(response.data as String) as Map<String, dynamic>;
    }
    return response.data as Map<String, dynamic>;
  }

  /// 获取分类列表
  /// GET {api}?ac=class
  Future<List<Category>> fetchCategories(Site site) async {
    final response = await _dio.get(
      site.api,
      queryParameters: {'ac': 'class'},
      options: Options(sendTimeout: const Duration(seconds: 8)),
    );
    final data = _decode(response);
    final list = data['class'] as List<dynamic>? ?? [];
    return list
        .map((e) => Category.fromJson(e as Map<String, dynamic>, siteKey: site.key))
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

    final response = await _dio.get(
      site.api,
      queryParameters: params,
      options: Options(sendTimeout: const Duration(seconds: 8)),
    );
    final data = _decode(response);
    return VideoListResult.fromJson(data, siteKey: site.key);
  }

  /// 获取视频详情
  /// GET {api}?ac=detail&ids={id}
  Future<CmsVideoDetail?> fetchVideoDetail({
    required Site site,
    required String videoId,
  }) async {
    final response = await _dio.get(
      site.api,
      queryParameters: {
        'ac': 'detail',
        'ids': videoId,
      },
      options: Options(sendTimeout: const Duration(seconds: 8)),
    );
    final data = _decode(response);
    final list = data['list'] as List<dynamic>? ?? [];
    if (list.isEmpty) return null;
    return CmsVideoDetail.fromJson(list[0] as Map<String, dynamic>);
  }

  /// 搜索
  /// GET {api}?wd={keyword}
  Future<VideoListResult> search({
    required Site site,
    required String keyword,
  }) async {
    final response = await _dio.get(
      site.api,
      queryParameters: {'wd': keyword},
      options: Options(sendTimeout: const Duration(seconds: 8)),
    );
    final data = _decode(response);
    return VideoListResult.fromJson(data, siteKey: site.key);
  }
}
