import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/source_config.dart';
import 'package:streambox/data/sources/source_health_checker.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';
import 'package:streambox/features/source/providers/source_provider.dart';
import 'package:streambox/features/source/source_manage_page.dart';

const root = SourceStorage.officialUrl;
const remote = 'https://remote.example/config.json';
const apiA = 'https://a.example/api.php';
const apiB = 'https://b.example/api.php';
const apiC = 'https://c.example/api.php';
Map<String, dynamic> inline(String title, String api) => {
  'title': title,
  'data': [
    {'id': 'main', 'name': title, 'url': api},
  ],
};
const external = {'title': 'B', 'data': remote};

void main() {
  late Directory temp;
  late SourceStorage storage;
  late _Adapter adapter;
  late Dio dio;
  late SourceLibraryNotifier library;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('streambox-review-');
    Hive.init(temp.path);
    storage = SourceStorage();
    await storage.init();
    adapter = _Adapter()
      ..documents.addAll({
        root: jsonEncode([inline('A', apiA), external]),
        remote: jsonEncode([
          {'id': 'b', 'name': 'B', 'url': apiB},
        ]),
      });
    dio = Dio()..httpClientAdapter = adapter;
    library = SourceLibraryNotifier(storage, SourceParser(dio));
  });
  tearDown(() async {
    if (library.mounted) library.dispose();
    dio.close(force: true);
    await Hive.close();
    await temp.delete(recursive: true);
  });
  Future<void> start() async {
    await library.restore();
    await library.refreshAll();
  }

  test(
    'reordering independent inline groups preserves home and enablement',
    () async {
      final a = inline('A', apiA);
      final b = inline('B', apiB);
      adapter.documents[root] = jsonEncode([a, b]);
      await start();
      final originalKeys = {
        for (final s in library.state.allSites) s.identity: s.key,
      };
      await library.selectHome(library.state.allSites.first);
      await library.setEnabled(library.state.allSites.first, false);
      adapter.documents[root] = jsonEncode([b, a]);
      await library.refresh(root);
      expect(library.state.homeIdentity, apiA);
      expect(
        library.state.allSites.singleWhere((s) => s.identity == apiB).isEnabled,
        isTrue,
      );
      expect({
        for (final s in library.state.allSites) s.identity: s.key,
      }, originalKeys);
      adapter.documents[root] = jsonEncode([b, inline('A', apiC)]);
      await library.refresh(root);
      expect(library.state.homeIdentity, apiC);
      expect(
        library.state.allSites.singleWhere((s) => s.identity == apiB).isEnabled,
        isTrue,
      );
      expect(
        library.state.allSites.singleWhere((s) => s.identity == apiC).isEnabled,
        isFalse,
      );
    },
  );

  test(
    'remote-only catalog failure preserves exactly the configured groups',
    () async {
      adapter.documents[root] = jsonEncode([external]);
      await start();
      expect(library.state.groups.keys, [remote]);
      adapter.failures.add(root);
      await library.refresh(root);
      expect(library.state.groups.keys, [remote]);
      expect(library.state.catalogStatus!.error, isNotNull);
      library.dispose();
      library = SourceLibraryNotifier(storage, SourceParser(dio));
      await start();
      expect(library.state.groups.keys, [remote]);
      expect(library.state.catalogStatus!.error, isNotNull);
    },
  );

  test('slow remote does not stop a subsequent catalog refresh', () async {
    final blocked = Completer<String>();
    adapter.blocked[remote] = blocked;
    await library.restore();
    final startup = library.refresh(root);
    await adapter.remoteStarted.future.timeout(const Duration(seconds: 2));
    try {
      await startup.timeout(const Duration(seconds: 1));
      adapter.documents[root] = jsonEncode([inline('A', apiC), external]);
      await library.refresh(root).timeout(const Duration(seconds: 1));
      expect(adapter.requests.where((u) => u == root), hasLength(2));
      expect(
        library.state.groups.values
            .singleWhere((g) => g.name == 'A')
            .config!
            .sites
            .single
            .api,
        apiC,
      );
      expect(adapter.requests.where((u) => u == remote), hasLength(1));
    } finally {
      blocked.complete(adapter.documents[remote]!);
      await library.refreshAll();
    }
  });

  testWidgets('reordering group tabs preserves focused group', (tester) async {
    final a = SourceGroup(
      url: root,
      title: 'A',
      config: const SourceConfig(sites: []),
    );
    final b = SourceGroup(
      url: remote,
      title: 'B',
      config: const SourceConfig(sites: []),
    );
    library.dispose();
    final view = _View(
      storage,
      SourceParser(dio),
      SourceLibrary(groups: {root: a, remote: b}),
    );
    library = view;
    final health = _Health();
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceLibraryProvider.overrideWith((ref) => view),
          sourceHealthProvider.overrideWith((ref) => health),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const SourceManagePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('A'))).hasPrimaryFocus, isTrue);
    view.replace(SourceLibrary(groups: {remote: b, root: a}));
    await tester.pumpAndSettle();
    final retainedFocus = Focus.of(
      tester.element(find.text('A')),
    ).hasPrimaryFocus;
    await tester.pumpWidget(const SizedBox());
    expect(retainedFocus, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

class _Adapter implements HttpClientAdapter {
  final documents = <String, String>{};
  final failures = <String>{};
  final blocked = <String, Completer<String>>{};
  final requests = <String>[];
  final remoteStarted = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
    if (url == remote && !remoteStarted.isCompleted) remoteStarted.complete();
    final text = blocked.containsKey(url)
        ? await blocked[url]!.future
        : documents[url] ?? '';
    return ResponseBody.fromString(
      text,
      failures.contains(url) ? 503 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _View extends SourceLibraryNotifier {
  _View(super.storage, super.parser, SourceLibrary initial) {
    state = initial;
  }
  void replace(SourceLibrary value) => state = value;
  @override
  Future<void> restore() async {}
}

class _Health extends SourceHealthNotifier {
  _Health() : super(SourceHealthChecker(Dio()));
}
