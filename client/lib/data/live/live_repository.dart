import 'dart:async';
import 'dart:convert';
import '../../core/config/live_sources.dart';
import '../models/live_source_catalog.dart';
import 'package:dio/dio.dart';
import '../../core/network/bounded_response.dart';
import '../../core/network/url_policy.dart';
import '../models/live_channel.dart';
import 'm3u_parser.dart';

class LiveRepository {
  final Dio dio;
  LiveRepository(this.dio);

  Future<LiveSourceCatalog> fetchCatalog({
    required CancelToken cancelToken,
  }) async {
    final uri = UrlPolicy.requireLiveConfigUrl(LiveSources.url);
    var secure = uri.scheme == 'https';
    final response = await getBoundedTextResponse(
      dio,
      uri.toString(),
      cancelToken: cancelToken,
      headers: const {'Cache-Control': 'no-cache'},
      extra: const {'skipRetry': true},
      receiveTimeout: const Duration(seconds: 10),
      redirectValidator: (next) {
        if (secure && next.scheme != 'https') {
          throw const FormatException('直播配置不允许从 HTTPS 降级到 HTTP');
        }
        UrlPolicy.requireLiveConfigUrl(next.toString());
        secure = next.scheme == 'https';
      },
      maxBytes: 256 * 1024,
    ).timeout(const Duration(seconds: 15));
    return LiveSourceCatalog.fromJson(jsonDecode(response.text));
  }

  Future<LivePlaylist> fetch(
    String url, {
    required CancelToken cancelToken,
    List<String> fallbackUrls = const [],
  }) async {
    final uri = UrlPolicy.requireConfigUrl(url);
    final response = await _fetchWithFallback(
      uri,
      cancelToken,
      fallbackUrls,
    ).timeout(const Duration(seconds: 25));
    return LivePlaylist(
      channels: parseLiveM3u(response.text, base: response.uri),
      updatedAt: DateTime.now(),
    );
  }

  Future<BoundedTextResponse> _fetchWithFallback(
    Uri uri,
    CancelToken token,
    List<String> fallbackUrls,
  ) async {
    final candidates = [uri, ...fallbackUrls.map(requireLiveCatalogUrl)];
    for (var i = 0; i < candidates.length; i++) {
      try {
        return await _fetchDocument(candidates[i], token);
      } catch (error) {
        final networkFailure =
            error is TimeoutException ||
            (error is DioException &&
                {
                  DioExceptionType.connectionTimeout,
                  DioExceptionType.receiveTimeout,
                  DioExceptionType.sendTimeout,
                  DioExceptionType.connectionError,
                }.contains(error.type));
        if (!networkFailure ||
            token.isCancelled ||
            i == candidates.length - 1) {
          rethrow;
        }
      }
    }
    throw StateError('缺少直播订阅下载地址');
  }

  Future<BoundedTextResponse> _fetchDocument(
    Uri uri,
    CancelToken cancelToken,
  ) => getBoundedTextResponse(
    dio,
    uri.toString(),
    cancelToken: cancelToken,
    headers: const {'Cache-Control': 'no-cache'},
    // Fail over rather than spending the entire request budget retrying the
    // same inaccessible origin. Other clients retain their existing retry.
    extra: const {'skipRetry': true},
    receiveTimeout: const Duration(seconds: 15),
    redirectValidator: (next) {
      UrlPolicy.requireConfigUrl(next.toString());
      // Remote redirects cannot enter a local/private service. An explicitly
      // entered local origin is retained for local development.
      if (next.host != uri.host) {
        UrlPolicy.requireCatalogApiUrl(next.toString());
      }
    },
    maxBytes: 5 * 1024 * 1024,
  );
}
