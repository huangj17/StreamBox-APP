import 'package:dio/dio.dart';
import 'retry_interceptor.dart';

/// 全局 Dio 实例
Dio createDio() {
  final dio = Dio(BaseOptions(
    // 部分 CMS 返回 text/html content-type，用 plain 统一手动解码
    responseType: ResponseType.plain,
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));

  // 重试拦截器：失败自动重试 1 次
  dio.interceptors.add(RetryInterceptor(dio: dio, maxRetries: 1));

  return dio;
}
