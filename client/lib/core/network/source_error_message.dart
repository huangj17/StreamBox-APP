import 'dart:async';

import 'package:dio/dio.dart';

/// A short source-loading message; keep the original exception in diagnostics.
String sourceErrorMessage(Object error) {
  if (error is DioException) {
    final cause = '${error.error ?? ''} ${error.message ?? ''}'.toLowerCase();
    if (cause.contains('failed host lookup') ||
        cause.contains('name or service not known') ||
        cause.contains('nodename nor servname provided')) {
      final host = error.requestOptions.uri.host;
      return host.isNotEmpty && host.length <= 100
          ? '无法解析域名 $host，请检查网络后重试'
          : '无法解析片源域名，请检查网络后重试';
    }
    if (cause.contains('certificate_verify_failed')) {
      return '片源的安全证书验证失败';
    }
    if (cause.contains('handshakeexception')) {
      return '无法与片源建立安全连接，请稍后重试';
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接片源超时，请稍后重试';
      case DioExceptionType.badCertificate:
        return '片源的安全证书验证失败';
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        if (status == 404) return '配置地址不存在，请检查地址';
        if (status == 401 || status == 403) return '片源服务器拒绝访问（$status）';
        if (status != null && status >= 500) return '片源服务器暂时异常（$status），请稍后重试';
        return status == null ? '片源服务器返回异常响应' : '片源服务器返回异常响应（$status）';
      case DioExceptionType.connectionError:
        return '无法连接片源，请检查网络后重试';
      case DioExceptionType.cancel:
        return '加载已取消';
      default:
        break;
    }
  }
  if (error is TimeoutException) return '连接片源超时，请稍后重试';
  if (error is FormatException) {
    final message = error.message;
    if (message.length <= 160 &&
        !message.contains('\n') &&
        RegExp(r'[\u4e00-\u9fff]').hasMatch(message)) {
      return message;
    }
    return '配置内容无效，请确认填写的是片源配置地址';
  }
  return '无法加载片源，请稍后重试或查看错误详情';
}
