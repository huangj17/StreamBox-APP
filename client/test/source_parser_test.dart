import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/source/providers/source_provider.dart';

void main() {
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
