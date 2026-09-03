import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/local/history_storage.dart';
import 'package:streambox/data/local/player_settings_storage.dart';
import 'package:streambox/data/models/episode.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/watch_history.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/player/engine/video_engine.dart';
import 'package:streambox/features/player/engine/video_engine_factory.dart';
import 'package:streambox/features/player/player_screen.dart';
import 'package:streambox/widgets/tv_button.dart';

void main() {
  late _Engine engine;
  late GoRouter router;

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage([null]),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (_) async => false,
    );
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 16));
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  String? focus() => FocusManager.instance.primaryFocus?.debugLabel;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    int count = 3,
    int groups = 2,
    int episode = 0,
    Size size = const Size(1280, 720),
    double textScale = 1,
    bool ready = true,
    bool startAtDetails = false,
  }) async {
    engine = _Engine();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    router = GoRouter(
      initialLocation: startAtDetails ? '/' : '/player',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => startAtDetails
              ? Scaffold(
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('详情页'),
                        TvActionButton.primary(
                          label: '继续观看',
                          autofocus: true,
                          debugLabel: 'detail-play',
                          onActivate: () => context.push('/player'),
                        ),
                      ],
                    ),
                  ),
                )
              : const Scaffold(body: Text('详情页')),
          routes: [
            GoRoute(
              path: 'player',
              builder: (_, _) => PlayerScreen(
                videoId: 'movie',
                site: Site.fromUrl('https://source.example/api', name: '测试片源'),
                videoTitle: '测试影片：这是一个较长的名字',
                cover: '',
                episodeGroups: List.generate(
                  groups,
                  (g) => List.generate(
                    count,
                    (i) => Episode(
                      name: '第 ${i + 1} 集',
                      url: 'https://video.example/$g/$i.m3u8',
                    ),
                  ),
                ),
                sourceNames: List.generate(groups, (g) => '线路 ${g + 1}'),
                initialEpisodeIndex: episode,
              ),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          videoEngineFactoryProvider.overrideWithValue(
            ({required bool hardwareDecode}) => engine,
          ),
          playerSettingsStorageProvider.overrideWithValue(_Settings()),
          historyStorageProvider.overrideWithValue(_History()),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
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
    if (ready && !startAtDetails) {
      engine.duration.add(const Duration(minutes: 90));
      engine.playing.add(true);
      engine.buffering.add(false);
      for (final ms in [0, 250, 500, 60500]) {
        engine.position.add(Duration(milliseconds: ms));
        await tester.pump();
      }
      await settle(tester);
    }
  }

  testWidgets('操作栏不误快进，时间轴松键跳转，取消后松键不会提交', (tester) async {
    await pumpPlayer(tester);
    expect(focus(), 'player:playPause');
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(focus(), 'player:next');
    expect(engine.seeks, isEmpty);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focus(), 'playerProgress');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(find.text('+10s · 松手跳转'), findsOneWidget);
    expect(engine.seeks, isEmpty);
    await tester.pump(const Duration(seconds: 8));
    expect(focus(), 'playerProgress');
    await key(tester, LogicalKeyboardKey.escape);
    expect(engine.seeks, isEmpty);
    expect(find.text('+10s · 松手跳转'), findsNothing);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(engine.seeks, isEmpty);
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(engine.seeks.single, const Duration(milliseconds: 50500));
    expect(focus(), 'playerProgress');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(engine.seeks.last, const Duration(milliseconds: 40500));
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.seeks.length, 2);
    expect(focus(), 'player:next');
  });

  testWidgets('回车退出播放后松键不会触发详情页继续观看', (tester) async {
    await pumpPlayer(tester, startAtDetails: true, ready: false);
    expect(focus(), 'detail-play');
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.byType(PlayerScreen), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowUp);
    await key(tester, LogicalKeyboardKey.arrowUp);
    expect(focus(), 'playerBack');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    // 按住确认直到旧实现有足够时间返回详情页，再松开以复现事件泄漏。
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.byType(PlayerScreen).hitTestable(), findsOneWidget);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('详情页').hitTestable(), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(engine.opens.length, 1);
    expect(focus(), 'detail-play');
  });

  testWidgets('隐藏时确认只唤起，暂停不自动收起，返回分层退出', (tester) async {
    await pumpPlayer(tester, count: 1, groups: 1);
    expect(find.byKey(const ValueKey('player-next')), findsNothing);
    expect(find.byKey(const ValueKey('player-previous')), findsNothing);
    expect(find.byKey(const ValueKey('player-episodes')), findsNothing);
    engine.buffering.add(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(focus(), 'player:playPause');
    engine.buffering.add(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    expect(focus(), 'playerRoot');
    await key(tester, LogicalKeyboardKey.enter);
    expect(focus(), 'player:playPause');
    expect(engine.toggleCount, 0);
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.toggleCount, 1);
    await tester.pump(const Duration(seconds: 8));
    expect(focus(), 'player:playPause');
    await key(tester, LogicalKeyboardKey.escape);
    expect(focus(), 'playerRoot');
    expect(find.text('详情页'), findsNothing);
    await key(tester, LogicalKeyboardKey.escape);
    expect(find.text('详情页'), findsOneWidget);
  });

  testWidgets('系统返回先关闭面板再收起控件，最后退出播放页', (tester) async {
    await pumpPlayer(tester, count: 1, groups: 1);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.text('播放设置'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('播放设置'), findsNothing);
    expect(focus(), 'player:settings');
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(focus(), 'playerRoot');
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('详情页'), findsOneWidget);
  });

  testWidgets('隐藏时方向键开始预览，长按松手只提交一次，无需确认', (tester) async {
    await pumpPlayer(tester);
    await key(tester, LogicalKeyboardKey.escape);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(focus(), 'playerProgress');
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(engine.seeks, isEmpty);
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.seeks, isEmpty);
    expect(focus(), 'playerProgress');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(engine.seeks.length, 1);
    expect(engine.seeks.single, greaterThan(const Duration(minutes: 3)));
  });

  testWidgets('快进时打开面板，松键不会把已取消的预览提交给引擎', (tester) async {
    await pumpPlayer(tester);
    await key(tester, LogicalKeyboardKey.arrowUp);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    await key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.text('播放设置'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(engine.seeks, isEmpty);
    await key(tester, LogicalKeyboardKey.escape);
    expect(focus(), 'playerProgress');
    expect(find.textContaining('确认跳转'), findsNothing);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(engine.seeks.single, const Duration(milliseconds: 70500));
  });

  testWidgets('选集定位第88集，跨屏导航到尾集，关闭恢复选集按钮', (tester) async {
    await pumpPlayer(tester, count: 100, episode: 87);
    for (var i = 0; i < 3; i++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focus(), 'player:episodes');
    await key(tester, LogicalKeyboardKey.enter);
    expect(focus(), 'playerPanel:87');
    expect(find.text('第 88 集').hitTestable(), findsOneWidget);
    for (var i = 0; i < 14; i++) {
      await key(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focus(), 'playerPanel:99');
    expect(find.text('第 100 集').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(focus(), 'playerPanel:99');
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.opens.last, 'https://video.example/0/99.m3u8');
    expect(focus(), 'player:episodes');
    expect(find.byKey(const ValueKey('player-next')), findsNothing);
  });

  testWidgets('设置支持逐层返回并恢复焦点，异步画质发现不改变当前设置项', (tester) async {
    await pumpPlayer(tester, count: 1, groups: 1);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.text('播放设置'), findsOneWidget);
    expect(focus(), 'playerPanel:0');
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.text('播放速度'), findsOneWidget);
    expect(focus(), 'playerPanel:2');
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.rates.single, 1.25);
    expect(find.text('播放设置'), findsOneWidget);
    expect(focus(), 'playerPanel:0');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(focus(), 'playerPanel:1'); // 音量
    engine.qualities.add(const [
      VideoQuality(id: 'hd', height: 1080),
      VideoQuality(id: 'sd', height: 720),
    ]);
    await settle(tester);
    expect(focus(), 'playerPanel:2'); // 仍然是音量
    await key(tester, LogicalKeyboardKey.escape);
    expect(focus(), 'player:settings');
    expect(engine.toggleCount, 0);
  });

  testWidgets('快速关闭侧栏后连续确认仍进入设置，视频视图不被重建', (tester) async {
    await pumpPlayer(tester, count: 1);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.enter);
    expect(find.text('切换线路'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.text('播放设置'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.text('播放速度'), findsOneWidget);
    expect(engine.videoBuildCount, 1);
    expect(engine.toggleCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换线路后恢复入口，未知时长的时间轴不会提交跳转', (tester) async {
    await pumpPlayer(tester);
    for (var i = 0; i < 3; i++) {
      await key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(focus(), 'player:sources');
    await key(tester, LogicalKeyboardKey.enter);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.opens.last, 'https://video.example/1/0.m3u8');
    expect(focus(), 'player:sources');
    await key(tester, LogicalKeyboardKey.arrowUp);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.seeks, isEmpty);
  });

  testWidgets('错误时焦点进入重试，重试后焦点仍有效', (tester) async {
    await pumpPlayer(tester, groups: 1);
    engine.errors.add('测试网络失败');
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(focus(), 'playerError:retry');
    expect(find.text('暂时无法播放'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.enter);
    expect(engine.opens.length, 2);
    expect(focus(), 'player:playPause');
    expect(find.text('暂时无法播放'), findsNothing);
  });

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(800, 390),
    const Size(960, 540),
  ]) {
    testWidgets('兼容窄屏和横屏 $size：触摸拖进度、滚动操作栏及设置面板', (tester) async {
      await pumpPlayer(tester, size: size, textScale: 1.3);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(Slider), const Offset(60, 0));
      await settle(tester);
      expect(engine.seeks, isNotEmpty);
      // 从时间轴返回操作栏，向右可访问屏幕外的设置按钮。
      await key(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 4; i++) {
        await key(tester, LogicalKeyboardKey.arrowRight);
      }
      expect(focus(), 'player:settings');
      expect(
        find.byKey(const ValueKey('player-settings')).hitTestable(),
        findsOneWidget,
      );
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('播放速度'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.escape);
      expect(focus(), 'player:settings');
    });
  }
}

class _Settings extends PlayerSettingsStorage {
  @override
  bool get hardwareDecode => true;
  @override
  double get defaultSpeed => 1;
}

class _History extends HistoryStorage {
  @override
  Future<void> save(WatchHistory history) async {}
}

class _Engine implements VideoEngine {
  final position = StreamController<Duration>.broadcast();
  final duration = StreamController<Duration>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final playing = StreamController<bool>.broadcast();
  final errors = StreamController<String>.broadcast();
  final qualities = StreamController<List<VideoQuality>>.broadcast();
  final opens = <String>[];
  final seeks = <Duration>[];
  final rates = <double>[];
  var toggleCount = 0;
  var videoBuildCount = 0;
  @override
  Stream<Duration> get positionStream => position.stream;
  @override
  Stream<Duration> get durationStream => duration.stream;
  @override
  Stream<bool> get bufferingStream => buffering.stream;
  @override
  Stream<bool> get playingStream => playing.stream;
  @override
  Stream<Duration> get bufferedStream => const Stream.empty();
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Stream<List<VideoQuality>> get qualitiesStream => qualities.stream;
  @override
  Stream<VideoQuality> get currentQualityStream => const Stream.empty();
  @override
  Widget buildVideoView() {
    videoBuildCount++;
    return const ColoredBox(color: Color(0xFF184B53));
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {
    opens.add(url);
  }

  @override
  Future<void> play() async {
    playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing.add(false);
  }

  @override
  Future<void> playOrPause() async {
    toggleCount++;
    playing.add(toggleCount.isEven);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Future<void> setVolume(double v01) async {}
  @override
  Future<void> setQuality(VideoQuality q) async {}
  @override
  Future<void> dispose() async {
    await Future.wait([
      position.close(),
      duration.close(),
      buffering.close(),
      playing.close(),
      errors.close(),
      qualities.close(),
    ]);
  }
}
