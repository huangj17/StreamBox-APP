import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class ResponseTooLargeException implements Exception {
  final int maxBytes;

  const ResponseTooLargeException(this.maxBytes);

  @override
  String toString() => '响应超过安全上限（$maxBytes bytes）';
}

/// Uses Dio's streaming response mode so chunked bodies are rejected before
/// the whole payload is retained in memory.
Future<String> getBoundedText(
  Dio dio,
  String url, {
  Map<String, dynamic>? queryParameters,
  Map<String, dynamic>? headers,
  Duration? sendTimeout,
  Duration? receiveTimeout,
  CancelToken? cancelToken,
  required int maxBytes,
}) async {
  final response = await dio.get<ResponseBody>(
    url,
    queryParameters: queryParameters,
    options: Options(
      responseType: ResponseType.stream,
      headers: headers,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
    ),
    cancelToken: cancelToken,
  );
  final declaredLength = int.tryParse(
    response.headers.value(Headers.contentLengthHeader) ?? '',
  );
  if (declaredLength != null && declaredLength > maxBytes) {
    throw ResponseTooLargeException(maxBytes);
  }
  final body = response.data;
  if (body == null) return '';
  final bytes = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in body.stream) {
    total += chunk.length;
    if (total > maxBytes) throw ResponseTooLargeException(maxBytes);
    bytes.add(Uint8List.fromList(chunk));
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: false);
}
