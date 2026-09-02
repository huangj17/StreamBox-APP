import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/local/history_storage.dart';
import 'package:streambox/data/local/player_settings_storage.dart';
import 'package:streambox/data/models/episode.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/watch_history.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/player/engine/video_engine.dart';
import 'package:streambox/features/player/engine/video_engine_factory.dart';
import 'package:streambox/features/player/player_screen.dart';

const _videoKey = ValueKey('test-video-surface');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  for (final viewport in [const Size(1000, 700), const Size(800, 600)]) {
    testWidgets('加载结束、控件隐藏和重新缓冲时视频区域保持铺满 $viewport', (tester) async {
      await tester.binding.setSurfaceSize(viewport);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final engine = _FakeEngine();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            videoEngineFactoryProvider.overrideWithValue(
              ({required bool hardwareDecode}) => engine,
            ),
            playerSettingsStorageProvider.overrideWithValue(_Settings()),
            historyStorageProvider.overrideWithValue(_History()),
          ],
          child: MaterialApp(
            home: PlayerScreen(
              videoId: 'test',
              site: Site.fromUrl('https://source.example/api', name: '测试片源'),
              videoTitle: '测试影片',
              cover: '',
              episodeGroups: const [
                [Episode(name: '正片', url: 'https://video.example/test.m3u8')],
              ],
              sourceNames: const ['线路一'],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.getSize(find.byKey(_videoKey)), viewport);

      // 模拟真实起播顺序：元数据、退出缓冲、连续时间推进。
      engine.duration.add(const Duration(minutes: 90));
      engine.playing.add(true);
      engine.buffering.add(false);
      for (final ms in [0, 250, 500]) {
        engine.position.add(Duration(milliseconds: ms));
        await tester.pump();
      }
      expect(find.text('正在缓冲'), findsNothing);
      expect(tester.getSize(find.byKey(_videoKey)), viewport);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getSize(find.byKey(_videoKey)), viewport);
      await tester.tapAt(Offset(viewport.width / 2, viewport.height / 2));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byIcon(Icons.arrow_back).hitTestable(), findsOneWidget);

      engine.buffering.add(true);
      await tester.pump();
      expect(tester.getSize(find.byKey(_videoKey)), viewport);
      engine.buffering.add(false);
      await tester.pump();
      expect(tester.getSize(find.byKey(_videoKey)), viewport);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

class _Settings extends PlayerSettingsStorage {
  @override
  bool get hardwareDecode => true;
  @override
  double get defaultSpeed => 1.0;
}

class _History extends HistoryStorage {
  @override
  Future<void> save(WatchHistory history) async {}
}

class _FakeEngine implements VideoEngine {
  final position = StreamController<Duration>.broadcast();
  final duration = StreamController<Duration>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final playing = StreamController<bool>.broadcast();

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
  Stream<String> get errorStream => const Stream.empty();
  @override
  Stream<List<VideoQuality>> get qualitiesStream => const Stream.empty();
  @override
  Stream<VideoQuality> get currentQualityStream => const Stream.empty();
  @override
  Widget buildVideoView() =>
      const ColoredBox(key: _videoKey, color: Colors.blue);
  @override
  Future<void> open(String url, {Map<String, String>? headers}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> setVolume(double v01) async {}
  @override
  Future<void> setQuality(VideoQuality q) async {}
  @override
  Future<void> dispose() async {
    await position.close();
    await duration.close();
    await buffering.close();
    await playing.close();
  }
}
