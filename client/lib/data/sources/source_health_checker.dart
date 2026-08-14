import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/network/bounded_response.dart';
import '../../core/network/gateway_auth.dart';
import '../../core/network/url_policy.dart';
import '../models/cms_video_detail.dart';
import '../models/source_health.dart';
import 'cms_xml_decoder.dart';
import 'source_parser.dart';

typedef SourceHostResolver =
    Future<List<InternetAddress>> Function(String host);

/// 片源健康检测器。
///
/// CMS 不只检查列表 API，还会从最新条目里抽取少量直链，继续
/// 检查 HLS 清单和首个分片/密钥。二进制资源只读第一个网络分块，
/// 避免健康检测产生大流量。
class SourceHealthChecker {
  static const _maxCmsBytes = 2 * 1024 * 1024;
  static const _maxPlaylistBytes = 512 * 1024;
  static const _requestTimeout = Duration(seconds: 4);
  static const _dnsTimeout = Duration(seconds: 2);
  static const _maxPlaybackCandidates = 2;
  static const _maxRedirects = 5;

  final Dio _dio;
  final SourceParser _parser;
  final SourceHostResolver _resolveHost;

  SourceHealthChecker(
    this._dio, {
    SourceParser? parser,
    SourceHostResolver? resolveHost,
  }) : _parser = parser ?? SourceParser(_dio),
       _resolveHost = resolveHost ?? InternetAddress.lookup;

  Future<SourceHealth> check(String sourceUrl) async {
    try {
      if (SourceParser.isJarBridgeUrl(sourceUrl)) {
        return await _checkGateway(sourceUrl);
      }
      if (SourceParser.isCmsApiUrl(sourceUrl)) {
        return await _checkCms(sourceUrl);
      }
      return await _checkConfig(sourceUrl);
    } catch (error) {
      return SourceHealth.unavailable(message: _friendlyError(error));
    }
  }

  Future<SourceHealth> _checkGateway(String sourceUrl) async {
    final origin = Uri.parse(sourceUrl);
    final config = await _parser.probeGateway(
      sourceUrl,
      redirectValidator: (uri) => _validateRedirect(
        uri,
        requireHttps: true,
        allowedLocalOrigin: origin,
      ),
    );
    if (config == null || config.sites.isEmpty) {
      return SourceHealth.unavailable(message: 'Bridge 未启动或没有可用插件');
    }
    return SourceHealth.unverified(
      message: 'Bridge 目录正常 · ${config.sites.length} 个插件，播放待验证',
    );
  }

  Future<SourceHealth> _checkConfig(String sourceUrl) async {
    final origin = Uri.parse(sourceUrl);
    final document = await _parser.parseDocument(
      sourceUrl,
      redirectValidator: (uri) => _validateRedirect(
        uri,
        requireHttps: true,
        allowedLocalOrigin: origin,
      ),
    );
    final warehouseCount = document.warehouses.length;
    if (warehouseCount > 0) {
      return SourceHealth.unverified(
        message: '配置正常 · $warehouseCount 个仓库，播放待验证',
      );
    }
    final siteCount = document.config?.sites.length ?? 0;
    if (siteCount > 0) {
      return SourceHealth.unverified(message: '配置正常 · $siteCount 个站点，播放待验证');
    }
    return SourceHealth.unavailable(message: '配置中没有可用站点或仓库');
  }

  Future<SourceHealth> _checkCms(String sourceUrl) async {
    final site = SourceParser.wrapCmsUrl(sourceUrl).sites.single;
    final headers = site.isBridge ? GatewayAuth.headers : null;
    final String payload;
    try {
      payload = await getBoundedText(
        _dio,
        site.api,
        queryParameters: const {'ac': 'detail', 'pg': 1},
        headers: headers,
        sendTimeout: _requestTimeout,
        receiveTimeout: _requestTimeout,
        redirectValidator: (uri) => _validateRedirect(
          uri,
          requireHttps: true,
          allowedLocalOrigin: Uri.parse(site.api),
        ),
        maxBytes: _maxCmsBytes,
      );
    } catch (error) {
      return SourceHealth.unavailable(
        message: '列表接口不可用：${_friendlyError(error)}',
      );
    }

    final data = _decodeCmsPayload(payload);
    final rawList = data['list'];
    if (rawList is! List || rawList.isEmpty) {
      return SourceHealth.unavailable(message: '列表接口未返回内容');
    }

    final candidates = _playbackCandidates(rawList);
    if (candidates.isEmpty) {
      return SourceHealth.unverified(message: '列表正常，未找到可直接检测的播放链接');
    }

    Object? lastError;
    for (final candidate in candidates) {
      try {
        await _probePlayback(candidate, headers: headers);
        return SourceHealth.available();
      } catch (error) {
        lastError = error;
      }
    }
    return SourceHealth.unavailable(
      message: '播放不可用：${_friendlyError(lastError ?? '未知错误')}',
    );
  }

  Map<String, dynamic> _decodeCmsPayload(String payload) {
    final trimmed = payload.trimLeft();
    if (trimmed.startsWith('<')) return decodeCmsXml(payload);
    final decoded = jsonDecode(payload);
    if (decoded is! Map) throw const FormatException('CMS 返回格式错误');
    return Map<String, dynamic>.from(decoded);
  }

  List<Uri> _playbackCandidates(List<dynamic> rawList) {
    final preferred = <Uri>[];
    final fallback = <Uri>[];
    final seen = <String>{};

    for (final raw in rawList.take(4)) {
      if (raw is! Map) continue;
      final detail = CmsVideoDetail.fromJson(Map<String, dynamic>.from(raw));
      for (final group in detail.episodeGroups) {
        for (final episode in group.reversed) {
          if (episode.requiresResolve || episode.url.isEmpty) continue;
          final uri = Uri.tryParse(episode.url.trim());
          if (uri == null || !uri.hasScheme || !seen.add(uri.toString())) {
            continue;
          }
          final path = uri.path.toLowerCase();
          if (path.endsWith('.m3u8')) {
            preferred.add(uri);
          } else if (_isDirectMediaPath(path)) {
            fallback.add(uri);
          }
          break;
        }
      }
    }

    return [...preferred, ...fallback].take(_maxPlaybackCandidates).toList();
  }

  bool _isDirectMediaPath(String path) =>
      path.endsWith('.mp4') ||
      path.endsWith('.mkv') ||
      path.endsWith('.webm') ||
      path.endsWith('.flv') ||
      path.endsWith('.ts');

  Future<void> _probePlayback(Uri uri, {Map<String, dynamic>? headers}) async {
    final validated = UrlPolicy.requirePlaybackUrl(uri.toString());
    if (validated.path.toLowerCase().endsWith('.m3u8')) {
      await _probeHls(validated, headers: headers, depth: 0);
    } else {
      await _probeBinary(validated, headers: headers);
    }
  }

  Future<void> _probeHls(
    Uri playlist, {
    Map<String, dynamic>? headers,
    required int depth,
  }) async {
    if (depth > 2) throw const _ProbeException('HLS 清单嵌套过深');
    await _ensurePublicDns(playlist.host);
    final response = await getBoundedTextResponse(
      _dio,
      playlist.toString(),
      headers: headers,
      sendTimeout: _requestTimeout,
      receiveTimeout: _requestTimeout,
      redirectValidator: (uri) => _validateRedirect(uri),
      maxBytes: _maxPlaylistBytes,
    );
    final text = response.text;
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const _ProbeException('播放地址未返回 HLS 清单');
    }

    // 发生跳转后，相对的 key/variant/segment 必须以最终清单地址为基准。
    final playlistBase = response.uri;
    final key = _hlsKeyUri(text, playlistBase);
    if (key != null) await _probeBinary(key, headers: headers);

    final media = _firstHlsUri(text, playlistBase);
    if (media == null) throw const _ProbeException('HLS 清单中没有媒体分片');
    // HLS variant URI 不要求带 .m3u8 后缀，按 master-playlist 指令判断。
    if (_isMasterPlaylist(text)) {
      await _probeHls(media, headers: headers, depth: depth + 1);
    } else {
      await _probeBinary(media, headers: headers);
    }
  }

  Uri? _hlsKeyUri(String playlist, Uri base) {
    final match = RegExp(
      r'^#EXT-X-KEY:.*URI="([^"]+)"',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(playlist);
    final raw = match?.group(1)?.trim();
    return raw == null || raw.isEmpty ? null : base.resolve(raw);
  }

  Uri? _firstHlsUri(String playlist, Uri base) {
    for (final line in const LineSplitter().convert(playlist)) {
      final value = line.trim();
      if (value.isEmpty || value.startsWith('#')) continue;
      return base.resolve(value);
    }
    return null;
  }

  bool _isMasterPlaylist(String playlist) => RegExp(
    r'^#EXT-X-STREAM-INF:',
    multiLine: true,
    caseSensitive: false,
  ).hasMatch(playlist);

  Future<void> _probeBinary(Uri uri, {Map<String, dynamic>? headers}) async {
    final validated = UrlPolicy.requirePlaybackUrl(uri.toString());
    await _ensurePublicDns(validated.host);
    var requestHeaders = <String, dynamic>{
      ...?headers,
      'Range': 'bytes=0-1023',
    };
    var current = validated;
    final visited = <String>{};

    for (var redirectCount = 0; ; redirectCount++) {
      final response = await _dio.get<ResponseBody>(
        current.toString(),
        options: Options(
          responseType: ResponseType.stream,
          headers: requestHeaders,
          sendTimeout: _requestTimeout,
          receiveTimeout: _requestTimeout,
          followRedirects: false,
          validateStatus: _isSuccessOrRedirect,
        ),
      );
      if (_isRedirect(response.statusCode)) {
        final redirectBody = response.data;
        if (redirectBody != null) {
          await redirectBody.stream.listen(null).cancel();
        }
        if (redirectCount >= _maxRedirects) {
          throw const _ProbeException('重定向次数过多');
        }
        final location = response.headers.value('location');
        if (location == null || location.trim().isEmpty) {
          throw const _ProbeException('重定向响应缺少 Location');
        }
        final next = response.requestOptions.uri.resolve(location.trim());
        if (!visited.add(next.toString())) {
          throw const _ProbeException('检测到重定向循环');
        }
        await _validateRedirect(next);
        if (!_sameOrigin(current, next)) {
          requestHeaders = _withoutSensitiveHeaders(requestHeaders);
        }
        current = next;
        continue;
      }

      final body = response.data;
      if (body == null) throw const _ProbeException('媒体分片为空');
      final firstChunk = await body.stream.first.timeout(_requestTimeout);
      if (firstChunk.isEmpty) throw const _ProbeException('媒体分片为空');
      return;
    }
  }

  Future<void> _validateRedirect(
    Uri uri, {
    bool requireHttps = false,
    Uri? allowedLocalOrigin,
  }) async {
    if (allowedLocalOrigin != null &&
        _isExplicitLoopbackHost(allowedLocalOrigin.host) &&
        _sameOrigin(uri, allowedLocalOrigin)) {
      return;
    }
    final validated = UrlPolicy.requirePlaybackUrl(uri.toString());
    if (requireHttps && validated.scheme != 'https') {
      throw const FormatException('远程重定向地址必须使用 HTTPS');
    }
    await _ensurePublicDns(validated.host);
  }

  bool _isExplicitLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.localhost')) {
      return true;
    }
    return InternetAddress.tryParse(normalized)?.isLoopback ?? false;
  }

  bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  Map<String, dynamic> _withoutSensitiveHeaders(Map<String, dynamic> headers) {
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

  bool _isSuccessOrRedirect(int? status) =>
      status != null &&
      ((status >= 200 && status < 300) || _isRedirect(status));

  bool _isRedirect(int? status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  Future<void> _ensurePublicDns(String host) async {
    final addresses = await _resolveHost(host).timeout(_dnsTimeout);
    if (addresses.isEmpty) throw const _ProbeException('播放域名无法解析');
    if (addresses.any(_isUnsafeAddress)) {
      throw const _ProbeException('播放域名已失效（解析到本机或私网）');
    }
  }

  bool _isUnsafeAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0];
      final b = bytes[1];
      return a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168) ||
          a >= 224;
    }
    return (bytes.isNotEmpty && (bytes[0] & 0xfe) == 0xfc) ||
        bytes.every((byte) => byte == 0);
  }

  String _friendlyError(Object error) {
    if (error is _ProbeException) return error.message;
    if (error is TimeoutException) return '连接超时';
    if (error is SocketException) return '域名解析或网络连接失败';
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null) return '返回 HTTP $statusCode';
      return switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => '连接超时',
        DioExceptionType.connectionError => '网络连接失败',
        _ => '请求失败',
      };
    }
    if (error is FormatException) return error.message;
    return error.toString().replaceFirst('Exception: ', '');
  }
}

class _ProbeException implements Exception {
  final String message;

  const _ProbeException(this.message);

  @override
  String toString() => message;
}
