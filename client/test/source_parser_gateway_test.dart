import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/source/providers/source_provider.dart';

void main() {
  test(
    'probeGateway supports custom HTTPS ports and filters unavailable sources',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _StringAdapter((options) {
          expect(
            options.uri.toString(),
            'https://gateway.example:8443/api/list',
          );
          return '''{
          "code": 200,
          "catalogVersion": "v2",
          "stale": false,
          "sources": [
            {"key":"cms","name":"CMS","api":"/api/cms","kind":"cms","status":"ready","searchable":true},
            {"key":"jar","name":"JAR","api":"api/jar","kind":"jar","status":"degraded","searchable":false},
            {"key":"bad","name":"Bad","api":"/api/bad","kind":"jar","status":"failed"}
          ]
        }''';
        });

      final config = await SourceParser(
        dio,
      ).probeGateway('https://gateway.example:8443');

      expect(config, isNotNull);
      expect(config!.sites, hasLength(2));
      expect(config.sites.first.sourceKind, SiteSourceKind.cms);
      expect(config.sites.first.gatewayStatus, GatewaySourceStatus.ready);
      expect(config.sites.first.api, 'https://gateway.example:8443/api/cms');
      expect(config.sites.last.sourceKind, SiteSourceKind.jar);
      expect(config.sites.last.gatewayStatus, GatewaySourceStatus.degraded);
      expect(config.sites.last.searchable, isFalse);
      expect(config.sites.last.api, 'https://gateway.example:8443/api/jar');
    },
  );

  test('probeGateway accepts a legacy Bridge source without kind', () async {
    final dio = Dio()
      ..httpClientAdapter = _StringAdapter(
        (_) =>
            '{"code":200,"sources":[{"key":"legacy","name":"Legacy","api":"/api/legacy"}]}',
      );

    final config = await SourceParser(
      dio,
    ).probeGateway('https://bridge.example');

    expect(config!.sites.single.sourceKind, SiteSourceKind.jar);
    expect(config.sites.single.gatewayStatus, GatewaySourceStatus.ready);
  });

  test('probeGateway rejects an unrelated HTTP 200 response', () async {
    final dio = Dio()
      ..httpClientAdapter = _StringAdapter((_) => '{"status":"ok"}');

    final config = await SourceParser(
      dio,
    ).probeGateway('https://not-a-gateway.example');

    expect(config, isNull);
  });

  test('a direct Bridge plugin endpoint keeps Gateway identity', () {
    const url = 'http://127.0.0.1:9978/api/hidden';

    expect(SourceParser.isJarBridgeUrl(url), isFalse);
    expect(SourceParser.isJarBridgePluginUrl(url), isTrue);
    expect(SourceParser.isCmsApiUrl(url), isTrue);
    final site = SourceParser.wrapCmsUrl(url).sites.single;
    expect(site.isBridge, isTrue);
    expect(site.api, url);
    expect(site.gatewayUrl, 'http://127.0.0.1:9978');
  });

  test(
    'warehouse detection and single-source parsing share one download',
    () async {
      var requests = 0;
      final dio = Dio()
        ..httpClientAdapter = _StringAdapter((options) {
          requests += 1;
          return '''{"sites":[{"key":"cms","name":"CMS","type":3,"api":"https://cms.example/api.php"}]}''';
        });
      final container = ProviderContainer(
        overrides: [
          dioProvider.overrideWithValue(dio),
          selectedSourceUrlProvider.overrideWith(
            (ref) => 'https://config.example/box.json',
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(await container.read(warehouseListProvider.future), isEmpty);
      expect(
        (await container.read(sourceConfigProvider.future))!.sites,
        hasLength(1),
      );
      expect(requests, 1);
    },
  );
}

class _StringAdapter implements HttpClientAdapter {
  final String Function(RequestOptions options) body;

  _StringAdapter(this.body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body(options),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
