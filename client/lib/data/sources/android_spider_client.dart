import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../core/network/url_policy.dart';
import '../models/site.dart';

/// The channel talks to an Android process inside this app, never a remote API.
class AndroidSpiderClient {
  static const channel = MethodChannel('com.streambox/spider');

  Future<Map<String, dynamic>> invoke(
    Site site,
    String method, {
    Map<String, dynamic> params = const {},
    CancelToken? cancelToken,
  }) async {
    if (!Site.supportsAndroidJar || !site.isJar || !site.isSupported) {
      throw const FormatException('该 JAR 片源仅支持 Android 设备');
    }
    if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
    final request = channel.invokeMapMethod<String, dynamic>('invoke', {
      'site': {...site.toJson(), 'identity': site.identity},
      'method': method,
      'params': params,
    });
    try {
      final envelope =
          await (cancelToken == null
                  ? request
                  : Future.any([
                      request,
                      cancelToken.whenCancel.then<Map<String, dynamic>?>(
                        (e) => throw e,
                      ),
                    ]))
              .timeout(const Duration(seconds: 45));
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (envelope == null || envelope['data'] is! String) {
        throw const FormatException('Android 插件没有返回有效数据');
      }
      final proxy = envelope['proxyOrigin'];
      if (proxy is String) UrlPolicy.registerAndroidProxy(proxy);
      final raw = envelope['data'] as String;
      if (utf8.encode(raw).length > 10 * 1024 * 1024) {
        throw const FormatException('插件响应过大');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('插件响应必须是 JSON 对象');
      }
      return decoded;
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? 'Android 插件加载失败');
    } on MissingPluginException {
      throw const FormatException('当前安装包没有 Android 插件宿主，请更新应用');
    }
  }
}
