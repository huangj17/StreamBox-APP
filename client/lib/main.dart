import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';
import 'core/platform/platform_service.dart';
import 'data/cover/cover_cache.dart';
import 'data/cover/providers.dart';
import 'data/local/app_settings_storage.dart';
import 'data/local/source_storage.dart';
import 'data/local/history_storage.dart';
import 'data/local/favorite_storage.dart';
import 'data/local/player_settings_storage.dart';
import 'data/local/search_history_storage.dart';
import 'features/source/providers/source_provider.dart';
import 'features/home/providers/categories_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isDesktop = defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  // media_kit 仅在桌面端使用（移动 / TV 走 video_player）
  if (isDesktop) {
    MediaKit.ensureInitialized();
  }

  // 检测当前 Android 设备是否为 TV（决定走 TV 布局还是手机布局）
  await PlatformService.init();

  // 桌面端初始化窗口管理
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1000, 700),       // 初始窗口尺寸（接近 10:7 比例）
        minimumSize: Size(800, 600), // 最小尺寸限制
        center: true,                // 居中显示
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  await Hive.initFlutter();

  // 并行初始化本地存储（减少冷启动耗时）
  final sourceStorage = SourceStorage();
  final historyStorage = HistoryStorage();
  final favoriteStorage = FavoriteStorage();
  final playerSettingsStorage = PlayerSettingsStorage();
  final searchHistoryStorage = SearchHistoryStorage();
  final appSettingsStorage = AppSettingsStorage();
  final coverCache = CoverCache();

  await Future.wait([
    sourceStorage.init(),
    historyStorage.init(),
    favoriteStorage.init(),
    playerSettingsStorage.init(),
    searchHistoryStorage.init(),
    appSettingsStorage.init(),
    coverCache.init(),
  ]);

  // 限制内存中图片缓存（默认 100MB / 1000 张，降至 50MB / 200 张以控制内存）
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 << 20; // 50 MB
  PaintingBinding.instance.imageCache.maximumSize = 200;

  runApp(ProviderScope(
    overrides: [
      // 注入已初始化的存储实例
      sourceStorageProvider.overrideWithValue(sourceStorage),
      historyStorageProvider.overrideWithValue(historyStorage),
      favoriteStorageProvider.overrideWithValue(favoriteStorage),
      playerSettingsStorageProvider.overrideWithValue(playerSettingsStorage),
      searchHistoryStorageProvider.overrideWithValue(searchHistoryStorage),
      appSettingsStorageProvider.overrideWithValue(appSettingsStorage),
      coverCacheProvider.overrideWithValue(coverCache),
    ],
    child: const StreamBoxApp(),
  ));
}

class StreamBoxApp extends StatelessWidget {
  const StreamBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'StreamBox',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      routerConfig: appRouter,
    );
  }
}
