import 'package:hive/hive.dart';

/// 播放器设置本地存储（Hive）
class PlayerSettingsStorage {
  static const _boxName = 'player_settings';

  // 存储 key
  static const _keyHardwareDecode = 'hardware_decode';
  static const _keyDefaultSpeed = 'default_speed';

  late Box _box;

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  /// 是否使用硬件解码（默认开启）
  bool get hardwareDecode => _box.get(_keyHardwareDecode, defaultValue: true) as bool;
  set hardwareDecode(bool value) => _box.put(_keyHardwareDecode, value);

  /// 默认播放倍速（1.0 = 正常）
  double get defaultSpeed =>
      (_box.get(_keyDefaultSpeed, defaultValue: 1.0) as num).toDouble();
  set defaultSpeed(double value) => _box.put(_keyDefaultSpeed, value);
}
