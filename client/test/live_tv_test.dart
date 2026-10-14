import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/models/live_channel.dart';
import 'package:streambox/data/models/live_source_catalog.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/live/live_screen.dart';
import 'package:streambox/features/live/live_subscriptions_screen.dart';
import 'package:streambox/features/live/providers/live_provider.dart';
import 'package:streambox/features/player/engine/video_engine_factory.dart';
import 'support/fake_live.dart';

void main() {
  late GoRouter router;
  late FakeLiveStorage storage;
  late FakeLiveRepository repository;
  final engines = <FakeLiveEngine>[];
  Completer<void>? nextOpen;
  final screenshotKey = GlobalKey();

  setUpAll(() async {
    const previewFont = String.fromEnvironment('LIVE_PREVIEW_FONT');
    const previewIcons = String.fromEnvironment('LIVE_PREVIEW_ICONS');
    if (previewFont.isNotEmpty) {
      final loader = FontLoader('LivePreview')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(previewFont).readAsBytes()),
          ),
        );
      await loader.load();
    }
    if (previewIcons.isNotEmpty) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(previewIcons).readAsBytes()),
          ),
        );
      await loader.load();
    }
  });

  setUp(() {
    engines.clear();
    nextOpen = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  String? focus() => FocusManager.instance.primaryFocus?.debugLabel;

  Future<void> pumpApp(
    WidgetTester tester, {
    String path = '/live',
    Size size = const Size(1280, 720),
    double scale = 1,
    bool cached = true,
    int? lastIndex,
    List<LiveChannel>? channels,
    bool empty = false,
    Completer<LivePlaylist>? playlistLoad,
    Future<void> Function(String)? openBehavior,
    LiveChannel? rememberedChannel,
    Completer<LiveSourceCatalog>? catalogLoad,
    bool managed = false,
    bool migratedCache = false,
    Completer<LivePlaylist>? channelLoad,
  }) async {
    storage = FakeLiveStorage();
    repository = FakeLiveRepository();
    if (managed) {
      storage.items = [...liveTestCatalog().subscriptions];
      storage.selection = storage.items.first.url;
    }
    if (catalogLoad != null) {
      repository.catalogResponse = () => catalogLoad.future;
    }
    if (empty) {
      storage.items = [];
      storage.selection = null;
    }
    if (playlistLoad != null) repository.response = (_) => playlistLoad.future;
    if (channelLoad != null) repository.response = (_) => channelLoad.future;
    if (lastIndex != null) {
      storage.last[storage.selection!] =
          (channels ?? liveChannels())[lastIndex].identity;
    }
    if (rememberedChannel != null) {
      storage.last[storage.selection!] = rememberedChannel.identity;
      storage.lastDetails[storage.selection!] = rememberedChannel;
    }
    if (cached) {
      for (final item in storage.items) {
        storage.cacheData[item.url] = LivePlaylist(
          channels: channels ?? liveChannels(),
          updatedAt: migratedCache
              ? DateTime.fromMillisecondsSinceEpoch(0)
              : DateTime.now(),
        );
      }
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    router = GoRouter(
      initialLocation: path,
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('首页')),
        ),
        GoRoute(path: '/live', builder: (_, _) => const LiveScreen()),
        GoRoute(
          path: '/live/subscriptions',
          builder: (_, _) => const LiveSubscriptionsScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveStorageProvider.overrideWithValue(storage),
          liveRepositoryProvider.overrideWithValue(repository),
          playerSettingsStorageProvider.overrideWithValue(FakeLiveSettings()),
          videoEngineFactoryProvider.overrideWithValue(({
            required bool hardwareDecode,
          }) {
            final engine = FakeLiveEngine()
              ..pendingOpen = nextOpen
              ..openResponse = openBehavior;
            nextOpen = null;
            engines.add(engine);
            return engine;
          }),
        ],
        child: MaterialApp.router(
          theme: const String.fromEnvironment('LIVE_PREVIEW_FONT').isEmpty
              ? AppTheme.dark
              : AppTheme.dark.copyWith(
                  textTheme: AppTheme.dark.textTheme.apply(
                    fontFamily: 'LivePreview',
                  ),
                ),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: screenshotKey, child: child!),
          ),
        ),
      ),
    );
    await settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      router.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> ready(WidgetTester tester) async {
    // No duration is published; IPTV clocks may start at a large live offset.
    for (final ms in [120000, 120250, 120500]) {
      engines.last.positions.add(Duration(milliseconds: ms));
      await tester.pump();
    }
    await settle(tester);
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('LIVE_SCREENSHOTS')) return;
    await tester.pump(const Duration(milliseconds: 250));
    await tester.runAsync(() async {
      final boundary =
          screenshotKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '/tmp/streambox-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> openSettings(WidgetTester tester) async {
    await key(tester, LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 3; i++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focus(), 'livePlayer:settings');
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('直播设置'), findsOneWidget);
    expect(focus(), 'live:add');
  }

  testWidgets(
    'TV: auto play remembered channel, group browsing keeps picture, select and back exit',
    (tester) async {
      await pumpApp(tester, lastIndex: 28);
      expect(engines.single.opens.single, endsWith('/28.m3u8'));
      expect(focus(), 'livePlayer:root');
      expect(find.text('选择订阅'), findsNothing);
      await ready(tester);
      await screenshot(tester, 'live-autoplay-tv');
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'livePlayer:channel:25');
      expect(find.text('测试频道 29').hitTestable(), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focus(), 'livePlayer:group:2');
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'livePlayer:channel:0');
      expect(find.text('3 个频道 · 央视频道'), findsOneWidget);
      expect(engines, hasLength(1)); // Browsing does not change playback.
      await screenshot(tester, 'live-groups-tv');
      await key(tester, LogicalKeyboardKey.select);
      expect(engines.last.opens.single, endsWith('/0.m3u8'));
      expect(focus(), 'livePlayer:root');
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(engines.last.opens.single, endsWith('/29.m3u8'));
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(engines.last.opens.single, endsWith('/0.m3u8'));
      await key(tester, LogicalKeyboardKey.select);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(focus(), 'livePlayer:root');
      await key(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('首页'), findsOneWidget);
      expect(engines.every((e) => e.disposed && e.seekCount == 0), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: first entry loads playlist then auto plays; loading and missing subscriptions stay operable',
    (tester) async {
      final load = Completer<LivePlaylist>();
      await pumpApp(tester, cached: false, playlistLoad: load);
      expect(find.text('正在准备直播'), findsOneWidget);
      expect(engines, isEmpty);
      expect(find.text('直播设置'), findsOneWidget);
      load.complete(
        LivePlaylist(channels: liveChannels(), updatedAt: DateTime.now()),
      );
      await settle(tester);
      expect(engines.single.opens.single, endsWith('/0.m3u8'));
      expect(focus(), 'livePlayer:root');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Cold entry restores the same station after playlist order and signed URLs change',
    (tester) async {
      const last = LiveChannel(
        name: 'CCTV-6',
        group: '央视频道',
        tvgId: 'cctv6',
        url: 'https://video.example/old.m3u8?token=expired',
      );
      final channels = [
        const LiveChannel(
          name: 'CCTV-1',
          group: '央视频道',
          url: 'https://video.example/first.m3u8',
        ),
        const LiveChannel(
          name: 'CCTV-6',
          group: '央视频道',
          tvgId: 'cctv6',
          url: 'https://video.example/new.m3u8?token=new',
        ),
        const LiveChannel(
          name: 'CCTV-6',
          group: '央视频道',
          tvgId: 'cctv6',
          url: 'https://video.example/backup.m3u8',
        ),
      ];
      await pumpApp(tester, channels: channels, rememberedChannel: last);
      expect(engines.single.opens.single, channels[1].url);
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'livePlayer:channel:1');
      expect(find.text('CCTV-6'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: no subscriptions opens settings and adding recovers autoplay',
    (tester) async {
      await pumpApp(tester, empty: true);
      expect(find.text('添加订阅，开始看电视'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'live:add');
      await key(tester, LogicalKeyboardKey.select);
      await tester.enterText(find.byType(TextField).first, '我的直播');
      await key(tester, LogicalKeyboardKey.arrowDown);
      await tester.enterText(
        find.byType(TextField).last,
        'https://custom.example/live.m3u',
      );
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.escape);
      expect(engines.last.opens.single, endsWith('/0.m3u8'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: settings disposes picture, source change auto plays, returning preserves channel',
    (tester) async {
      await pumpApp(tester, lastIndex: 12);
      await openSettings(tester);
      expect(engines.single.disposed, isTrue);
      await key(tester, LogicalKeyboardKey.escape);
      expect(engines.last.opens.single, endsWith('/12.m3u8'));
      expect(focus(), 'livePlayer:root');
      await openSettings(tester);
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'live:use:0');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'live:use:1');
      await key(tester, LogicalKeyboardKey.select);
      expect(storage.selection, liveTestSubscriptions[1].url);
      expect(engines.last.opens.single, endsWith('/0.m3u8'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        find.text('直播设置'),
        findsOneWidget,
      ); // Collapsed player action only.
      expect(find.text('添加订阅'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: duplicate addresses are lines, metadata excluded, last line restored, channel keys skip lines',
    (tester) async {
      final channels = [
        const LiveChannel(
          name: '2026-08-27 14:06:22',
          group: '更新时间',
          url: 'https://video.example/meta',
        ),
        const LiveChannel(
          name: 'CCTV-1',
          group: '央视频道',
          url: 'https://video.example/one',
        ),
        const LiveChannel(
          name: 'CCTV-1',
          group: '央视频道',
          url: 'https://video.example/backup',
          headers: {'User-Agent': 'IPTV'},
        ),
        const LiveChannel(
          name: 'CCTV-2',
          group: '央视频道',
          url: 'https://video.example/two',
        ),
      ];
      await pumpApp(tester, channels: channels, lastIndex: 2);
      expect(engines.single.opens.single, endsWith('/backup'));
      expect(engines.single.headers.single, {'User-Agent': 'IPTV'});
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('2 个频道 · 央视频道'), findsOneWidget);
      expect(find.text('CCTV-1'), findsOneWidget);
      expect(find.textContaining('2026-08-27'), findsNothing);
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.channelDown);
      expect(engines.last.opens.single, endsWith('/two'));
      await key(tester, LogicalKeyboardKey.channelUp);
      expect(engines.last.opens.single, endsWith('/backup'));
      await key(tester, LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focus(), 'livePlayer:line');
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'live:choice:1');
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.select);
      expect(engines.last.opens.single, endsWith('/one'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: fresh install loads remote JSON then M3U and automatically plays',
    (tester) async {
      final catalog = Completer<LiveSourceCatalog>();
      await pumpApp(tester, empty: true, catalogLoad: catalog);
      expect(find.text('正在准备直播'), findsOneWidget);
      expect(engines, isEmpty);
      catalog.complete(liveTestCatalog());
      await settle(tester);
      expect(storage.selection, liveTestRecommendation.url);
      expect(engines.single.opens.single, endsWith('/0.m3u8'));
      expect(focus(), 'livePlayer:root');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Changed subscription endpoint downloads its new M3U before using borrowed cache',
    (tester) async {
      final channelLoad = Completer<LivePlaylist>();
      await pumpApp(tester, migratedCache: true, channelLoad: channelLoad);
      expect(engines, isEmpty);
      expect(find.text('正在准备直播'), findsOneWidget);
      channelLoad.complete(
        LivePlaylist(
          channels: [
            const LiveChannel(
              name: '新频道',
              group: '分组',
              url: 'https://new.example/video.m3u8',
            ),
          ],
          updatedAt: DateTime.now(),
        ),
      );
      await settle(tester);
      expect(engines.single.opens.single, 'https://new.example/video.m3u8');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Unreachable changed endpoint still falls back to borrowed channel cache',
    (tester) async {
      final channelLoad = Completer<LivePlaylist>();
      await pumpApp(tester, migratedCache: true, channelLoad: channelLoad);
      expect(engines, isEmpty);
      channelLoad.completeError(const FormatException('新订阅暂不可用'));
      await settle(tester);
      expect(engines.single.opens.single, endsWith('/0.m3u8'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: remote configuration update is reachable and failure retains subscriptions and focus',
    (tester) async {
      await pumpApp(tester, path: '/live/subscriptions');
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'live:catalogRefresh');
      final load = Completer<LiveSourceCatalog>();
      repository.catalogResponse = () => load.future;
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('正在同步服务器直播订阅…'), findsOneWidget);
      expect(focus(), 'live:catalogRefresh');
      load.completeError(const FormatException('bad catalog'));
      await settle(tester);
      expect(find.textContaining('继续使用缓存'), findsOneWidget);
      expect(storage.items, hasLength(2));
      expect(focus(), 'live:catalogRefresh');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'TV: server removal restores focus from deleted row to configuration update',
    (tester) async {
      final load = Completer<LiveSourceCatalog>();
      await pumpApp(
        tester,
        path: '/live/subscriptions',
        managed: true,
        catalogLoad: load,
      );
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focus(), 'live:use:0');
      load.complete(LiveSourceCatalog.fromJson([]));
      await settle(tester);
      expect(storage.items, isEmpty);
      expect(focus(), 'live:catalogRefresh');
      expect(find.text('暂无订阅，请添加 M3U 地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [const Size(390, 844), const Size(800, 390)]) {
    testWidgets(
      'Remote config settings remains scrollable at $size with large fonts',
      (tester) async {
        await pumpApp(
          tester,
          path: '/live/subscriptions',
          size: size,
          scale: 1.3,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('更新直播配置'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await screenshot(tester, 'live-json-settings-${size.width.toInt()}');
      },
    );
  }

  List<LiveChannel> backupChannels() => [
    for (var i = 0; i < 3; i++)
      LiveChannel(
        name: 'CCTV-1',
        group: '央视频道',
        url: 'https://video.example/backup/$i.m3u8',
        headers: {'User-Agent': 'line-$i'},
      ),
    const LiveChannel(
      name: 'CCTV-2',
      group: '央视频道',
      url: 'https://video.example/other.m3u8',
    ),
  ];

  testWidgets(
    'Auto lines: open failures wrap once from remembered line and remember successful backup',
    (tester) async {
      final channels = backupChannels();
      await pumpApp(
        tester,
        channels: channels,
        lastIndex: 1,
        openBehavior: (url) => url.endsWith('/0.m3u8')
            ? Future.value()
            : Future.error(StateError('open failed')),
      );
      expect(engines.map((e) => e.opens.single).toList(), [
        channels[1].url,
        channels[2].url,
        channels[0].url,
      ]);
      expect(engines.take(2).every((e) => e.disposed), isTrue);
      expect(engines.last.headers.single, {'User-Agent': 'line-0'});
      expect(find.text('该频道暂时无法播放'), findsNothing);
      expect(find.text('正在尝试备用线路…'), findsOneWidget);
      await ready(tester);
      expect(storage.last.values.single, channels[0].identity);
      await tester.pump(const Duration(seconds: 60));
      expect(engines, hasLength(3));
      expect(focus(), 'livePlayer:root');
      expect(find.text('正在尝试备用线路…'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Auto lines: timeouts try all lines once, ignore late open and retry resets the cycle',
    (tester) async {
      final channels = backupChannels();
      final firstOpen = Completer<void>();
      await pumpApp(
        tester,
        channels: channels,
        openBehavior: (url) =>
            url == channels[0].url ? firstOpen.future : Future.value(),
      );
      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(engines, hasLength(2));
      expect(engines.last.opens.single, channels[1].url);
      expect(find.text('该频道暂时无法播放'), findsNothing);
      firstOpen.completeError(StateError('late failure'));
      await settle(tester);
      expect(engines, hasLength(2));
      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(engines, hasLength(3));
      expect(engines.last.opens.single, channels[2].url);
      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(find.text('该频道暂时无法播放'), findsOneWidget);
      expect(find.textContaining('已尝试全部 3 条线路'), findsOneWidget);
      expect(engines.every((e) => e.disposed), isTrue);
      expect(focus(), 'livePlayer:retry');
      await tester.pump(const Duration(minutes: 3));
      expect(engines, hasLength(3));
      await key(tester, LogicalKeyboardKey.select);
      expect(engines.last.opens.single, channels[2].url);
      engines.last.errors.add('retry failed');
      await settle(tester);
      // Line 0 still returns the completed failed open; it must be tried again
      // in the new cycle, then fall through to the remaining line 1.
      expect(engines.skip(3).map((e) => e.opens.single).toList(), [
        channels[2].url,
        channels[0].url,
        channels[1].url,
      ]);
      expect(find.text('该频道暂时无法播放'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Auto lines: stalled buffering and subsequent errors exhaust only this channel',
    (tester) async {
      final channels = backupChannels();
      await pumpApp(tester, channels: channels);
      await ready(tester);
      engines.last.buffers.add(true);
      await settle(tester);
      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(engines.last.opens.single, channels[1].url);
      engines.last.errors.add('decoder failed');
      engines.last.errors.add('duplicate error');
      await settle(tester);
      expect(engines, hasLength(3));
      expect(engines.last.opens.single, channels[2].url);
      await ready(tester);
      expect(storage.last.values.single, channels[2].identity);
      engines.last.errors.add('stream lost');
      await settle(tester);
      expect(find.textContaining('已尝试全部 3 条线路'), findsOneWidget);
      expect(engines, hasLength(3));
      expect(
        engines.map((e) => e.opens.single),
        isNot(contains(channels[3].url)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Auto lines: channel panel and manual line picker retain focus during fallback',
    (tester) async {
      final channels = backupChannels();
      await pumpApp(tester, channels: channels);
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'livePlayer:channel:0');
      engines.last.errors.add('network failed');
      await settle(tester);
      expect(engines.last.opens.single, channels[1].url);
      expect(focus(), 'livePlayer:channel:0');
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      await key(tester, LogicalKeyboardKey.select);
      expect(focus(), 'live:choice:1');
      engines.last.errors.add('network failed');
      await settle(tester);
      expect(engines.last.opens.single, channels[2].url);
      expect(focus(), 'live:choice:1');
      engines.last.errors.add('network failed');
      await settle(tester);
      expect(focus(), 'live:choice:1');
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'livePlayer:line');
      expect(find.textContaining('已尝试全部 3 条线路'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('首页'), findsOneWidget);
      expect(engines.every((e) => e.disposed), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Auto lines: manual choice restarts attempts and channel switching cancels the previous cycle',
    (tester) async {
      final channels = backupChannels();
      final oldOpen = Completer<void>();
      await pumpApp(
        tester,
        channels: channels,
        openBehavior: (url) =>
            url == channels[1].url ? oldOpen.future : Future.value(),
      );
      engines.last.errors.add('network failed');
      await settle(tester);
      expect(engines.last.opens.single, channels[1].url);
      await key(tester, LogicalKeyboardKey.arrowRight);
      for (var i = 0; i < 3; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.select);
      expect(engines.last.opens.single, channels[2].url);
      engines.last.errors.add('manual line failed');
      await settle(tester);
      expect(engines.last.opens.single, channels[0].url);
      await key(tester, LogicalKeyboardKey.channelDown);
      expect(engines.last.opens.single, channels[3].url);
      await ready(tester);
      oldOpen.completeError(StateError('old channel late failure'));
      await settle(tester);
      await tester.pump(const Duration(seconds: 26));
      expect(engines.last.opens.single, channels[3].url);
      expect(find.text('该频道暂时无法播放'), findsNothing);
      await key(tester, LogicalKeyboardKey.channelUp);
      expect(engines.last.opens.single, channels[2].url);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: stale opens, zero duration, hidden controls, retry, timeout and system back',
    (tester) async {
      await pumpApp(tester);
      nextOpen = Completer<void>();
      final oldOpen = nextOpen!;
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowDown);
      oldOpen.completeError(StateError('旧频道迟到的错误'));
      await settle(tester);
      expect(find.text('该频道暂时无法播放'), findsNothing);
      await ready(tester);
      expect(storage.last.values.single, liveChannels()[2].identity);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('直播设置'), findsNothing);
      expect(focus(), 'livePlayer:root');
      await key(tester, LogicalKeyboardKey.select);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('返回直播'), findsNothing);
      engines.last.errors.add('network failed');
      await settle(tester);
      expect(focus(), 'livePlayer:retry');
      await key(tester, LogicalKeyboardKey.select);
      expect(engines.last.opens.single, endsWith('/2.m3u8'));
      await tester.pump(const Duration(seconds: 26));
      await settle(tester);
      expect(find.text('该频道暂时无法播放'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.channelDown);
      expect(engines.last.opens.single, endsWith('/3.m3u8'));
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('首页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('TV: failed playback exposes settings without exiting live', (
    tester,
  ) async {
    await pumpApp(tester);
    engines.last.errors.add('network timeout');
    await settle(tester);
    expect(find.text('测试频道 1 · ngo5 IPTV · IPv4'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focus(), 'livePlayer:switchSubscription');
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text('直播设置'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(engines.last.opens.single, endsWith('/0.m3u8'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TV: cancel add, refresh error preserves cached playback, remove confirmation',
    (tester) async {
      await pumpApp(tester);
      await openSettings(tester);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'live:add');
      repository.response = (_) =>
          Future.error(const FormatException('订阅服务器暂不可用'));
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'live:subscriptionRefresh:0');
      await key(tester, LogicalKeyboardKey.select);
      expect(find.textContaining('订阅服务器暂不可用'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.text('移除直播订阅'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.escape);
      expect(storage.items, hasLength(2));
      await key(tester, LogicalKeyboardKey.escape);
      expect(engines.last.opens.single, endsWith('/0.m3u8'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TV: cold download failure can retry and removal selects another subscription',
    (tester) async {
      final load = Completer<LivePlaylist>();
      await pumpApp(tester, cached: false, playlistLoad: load);
      load.completeError(const FormatException('获取频道失败'));
      await settle(tester);
      expect(find.text('暂无可用频道'), findsOneWidget);
      repository.response = (_) => Future.value(
        LivePlaylist(channels: liveChannels(), updatedAt: DateTime.now()),
      );
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(engines.last.opens.single, endsWith('/0.m3u8'));
      await openSettings(tester);
      await key(tester, LogicalKeyboardKey.arrowDown);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focus(), 'live:remove:0');
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(storage.items, hasLength(1));
      expect(storage.selection, liveTestSubscriptions[1].url);
      await key(tester, LogicalKeyboardKey.escape);
      expect(engines.last.opens.single, endsWith('/0.m3u8'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Background pause and resume reopen current channel without seeking',
    (tester) async {
      await pumpApp(tester);
      await key(tester, LogicalKeyboardKey.arrowDown);
      final paused = engines.last;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await settle(tester);
      expect(paused.pauseCount, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(paused.disposed, isTrue);
      expect(engines.last.opens.single, endsWith('/1.m3u8'));
      expect(engines.last.seekCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(960, 540),
    const Size(390, 844),
    const Size(800, 390),
  ]) {
    testWidgets('Layout and touch autoplay at $size, text scale 1.3', (
      tester,
    ) async {
      await pumpApp(tester, size: size, scale: 1.3);
      await ready(tester);
      await tester.tap(find.text('频道列表'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await screenshot(tester, 'live-redesign-${size.width.toInt()}');
      if (size.width < 760 || size.height < 500) {
        await tester.tap(find.text('选择分组'));
        await settle(tester);
        await key(tester, LogicalKeyboardKey.arrowDown);
        await key(tester, LogicalKeyboardKey.select);
        expect(tester.takeException(), isNull);
      }
      await key(tester, LogicalKeyboardKey.escape);
      engines.last.errors.add('network');
      await settle(tester);
      expect(find.text('该频道暂时无法播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await key(tester, LogicalKeyboardKey.select);
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.text('首页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
