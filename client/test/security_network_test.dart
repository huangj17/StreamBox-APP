import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/core/network/bounded_response.dart';
import 'package:streambox/core/network/url_policy.dart';
import 'package:streambox/data/models/source_config.dart';

void main() {
  group('URL policy', () {
    test('remote configuration and gateway require HTTPS', () {
      expect(
        () => UrlPolicy.requireConfigUrl('http://example.com/config.json'),
        throwsFormatException,
      );
      expect(
        () => UrlPolicy.requireGatewayUrl('http://192.168.1.10:9978'),
        throwsFormatException,
      );
      expect(
        UrlPolicy.requireGatewayUrl('http://127.0.0.1:9978').host,
        '127.0.0.1',
      );
    });

    test('playback rejects local resources and non HTTP protocols', () {
      expect(
        () => UrlPolicy.requirePlaybackUrl('file:///etc/passwd'),
        throwsFormatException,
      );
      expect(
        () => UrlPolicy.requirePlaybackUrl('http://127.0.0.1/private'),
        throwsFormatException,
      );
      expect(
        UrlPolicy.requirePlaybackUrl('https://media.example/video.m3u8').host,
        'media.example',
      );
      expect(
        UrlPolicy.requirePlaybackUrl('http://media.example/video.m3u8').host,
        'media.example',
      );
    });

    test('unsafe CMS sites from remote configuration are filtered out', () {
      final config = SourceConfig.fromJson({
        'sites': [
          {'key': 'safe', 'api': 'https://cms.example/api', 'type': 3},
          {'key': 'plain', 'api': 'http://cms.example/api', 'type': 3},
          {'key': 'local', 'api': 'https://127.0.0.1/api', 'type': 3},
        ],
      });

      expect(config.cmsSites.map((site) => site.key), ['safe']);
    });
  });

  test(
    'bounded response rejects chunked bodies before retaining all bytes',
    () async {
      final dio = Dio()..httpClientAdapter = _ChunkedAdapter();

      await expectLater(
        getBoundedText(dio, 'https://example.com', maxBytes: 8),
        throwsA(isA<ResponseTooLargeException>()),
      );
    },
  );
}

class _ChunkedAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody(
      Stream.fromIterable([
        Uint8List.fromList([1, 2, 3, 4, 5]),
        Uint8List.fromList([6, 7, 8, 9, 10]),
      ]),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
