import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/core/network/source_error_message.dart';

void main() {
  final options = RequestOptions(path: 'https://9280.kstore.vip/newwex.json');

  test(
    'DNS failures explain the failed host without exception boilerplate',
    () {
      final error = DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const SocketException("Failed host lookup: '9280.kstore.vip'"),
      );
      expect(sourceErrorMessage(error), '无法解析域名 9280.kstore.vip，请检查网络后重试');
      expect(sourceErrorMessage(error), isNot(contains('DioException')));
    },
  );

  test('timeout, HTTP response and TLS errors have distinct messages', () {
    expect(
      sourceErrorMessage(TimeoutException('Future not completed')),
      contains('超时'),
    );
    for (final status in [403, 404, 503]) {
      final error = DioException(
        requestOptions: options,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: options, statusCode: status),
      );
      expect(
        sourceErrorMessage(error),
        contains(
          status == 404
              ? '地址不存在'
              : status == 403
              ? '拒绝访问'
              : '暂时异常',
        ),
      );
    }
    expect(
      sourceErrorMessage(
        DioException(
          requestOptions: options,
          error: const HandshakeException(
            'Connection terminated during handshake',
          ),
        ),
      ),
      contains('安全连接'),
    );
    expect(
      sourceErrorMessage(
        DioException(
          requestOptions: options,
          error: const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ),
      ),
      contains('证书验证失败'),
    );
  });

  test('validation remains useful and malformed content is summarized', () {
    expect(sourceErrorMessage(const FormatException('配置中没有片源')), '配置中没有片源');
    expect(
      sourceErrorMessage(
        const FormatException('Unexpected character', '<html>'),
      ),
      '配置内容无效，请确认填写的是片源配置地址',
    );
  });
}
