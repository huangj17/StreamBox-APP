import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 全局图片磁盘缓存管理器
/// - 最大 200MB 磁盘缓存
/// - 7 天过期自动清理
class AppImageCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'streambox_image_cache';

  static final AppImageCacheManager _instance = AppImageCacheManager._();
  factory AppImageCacheManager() => _instance;

  AppImageCacheManager._()
      : super(Config(
          key,
          maxNrOfCacheObjects: 500,
          stalePeriod: const Duration(days: 7),
        ));
}
