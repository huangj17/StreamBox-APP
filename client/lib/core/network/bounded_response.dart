import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class ResponseTooLargeException implements Exception {
  final int maxBytes;

  const ResponseTooLargeException(this.maxBytes);

  @override
  String toString() => '响应超过安全上限（$maxBytes bytes）';
}

typedef RedirectUriValidator = FutureOr<void> Function(Uri uri);

class BoundedTextResponse {
  final String text;
  final Uri uri;

  const BoundedTextResponse({required this.text, required this.uri});
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
  RedirectUriValidator? redirectValidator,
  int maxRedirects = 5,
  required int maxBytes,
}) async {
  final response = await getBoundedTextResponse(
    dio,
    url,
    queryParameters: queryParameters,
    headers: headers,
    sendTimeout: sendTimeout,
    receiveTimeout: receiveTimeout,
    cancelToken: cancelToken,
    redirectValidator: redirectValidator,
    maxRedirects: maxRedirects,
    maxBytes: maxBytes,
  );
  return response.text;
}

/// 与 [getBoundedText] 相同，但同时返回最终响应 URI。
///
/// 传入 [redirectValidator] 时关闭 Dio 的自动跳转，在发出下一跳请求前逐个
/// 校验目标地址。这样调用方可以阻止不可信源通过 30x 访问本机或私网。
Future<BoundedTextResponse> getBoundedTextResponse(
  Dio dio,
  String url, {
  Map<String, dynamic>? queryParameters,
  Map<String, dynamic>? headers,
  Duration? sendTimeout,
  Duration? receiveTimeout,
  CancelToken? cancelToken,
  RedirectUriValidator? redirectValidator,
  int maxRedirects = 5,
  required int maxBytes,
}) async {
  var currentUrl = url;
  var currentQuery = queryParameters;
  var currentHeaders = headers;
  final visited = <String>{};

  for (var redirectCount = 0; ; redirectCount++) {
    final manualRedirects = redirectValidator != null;
    final response = await dio.get<ResponseBody>(
      currentUrl,
      queryParameters: currentQuery,
      options: Options(
        responseType: ResponseType.stream,
        headers: currentHeaders,
        sendTimeout: sendTimeout,
        receiveTimeout: receiveTimeout,
        followRedirects: !manualRedirects,
        validateStatus: manualRedirects ? _isSuccessOrRedirect : null,
      ),
      cancelToken: cancelToken,
    );

    if (manualRedirects && _isRedirect(response.statusCode)) {
      final body = response.data;
      if (body != null) await body.stream.listen(null).cancel();
      if (redirectCount >= maxRedirects) {
        throw const FormatException('重定向次数过多');
      }
      final location = response.headers.value('location');
      if (location == null || location.trim().isEmpty) {
        throw const FormatException('重定向响应缺少 Location');
      }
      final from = response.requestOptions.uri;
      final next = from.resolve(location.trim());
      if (!visited.add(next.toString())) {
        throw const FormatException('检测到重定向循环');
      }
      await redirectValidator(next);
      currentHeaders = _headersForRedirect(currentHeaders, from, next);
      currentUrl = next.toString();
      currentQuery = null;
      continue;
    }

    return BoundedTextResponse(
      text: await _readBoundedBody(response, maxBytes),
      uri: response.requestOptions.uri,
    );
  }
}

Future<String> _readBoundedBody(
  Response<ResponseBody> response,
  int maxBytes,
) async {
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

bool _isSuccessOrRedirect(int? status) =>
    status != null && ((status >= 200 && status < 300) || _isRedirect(status));

bool _isRedirect(int? status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

Map<String, dynamic>? _headersForRedirect(
  Map<String, dynamic>? headers,
  Uri from,
  Uri to,
) {
  if (headers == null || _sameOrigin(from, to)) return headers;
  final copied = Map<String, dynamic>.from(headers);
  copied.removeWhere((key, _) {
    final lower = key.toLowerCase();
    return lower == 'authorization' ||
        lower == 'www-authenticate' ||
        lower == 'cookie' ||
        lower == 'cookie2';
  });
  return copied;
}

bool _sameOrigin(Uri left, Uri right) =>
    left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
    left.host.toLowerCase() == right.host.toLowerCase() &&
    left.port == right.port;
