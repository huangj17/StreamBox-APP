import 'package:hive/hive.dart';

/// 配置源 URL 持久化存储
class SourceStorage {
  static const _boxName = 'source_urls';

  /// 内置片源（预置源，不可删除）
  static const builtInUrls = [
    // 自建 JAR Bridge 服务（放最前，方便用户识别）
    'http://1.14.171.39:9978',
    'https://jyzyapi.com/api.php/provide/vod/',
    'https://www.hongniuzy2.com/api.php/provide/vod/',
    'https://bfzyapi.com/api.php/provide/vod/',
    'https://www.tyyszy.com/api.php/provide/vod/',
    'https://collect.wolongzyw.com/api.php/provide/vod/',
    'https://api.apibdzy.com/api.php/provide/vod/',
  ];

  /// 预置第三方片源
  static const thirdPartyUrls = [
    'https://www.iyouhun.com/tv/fxz',
    'https://www.iyouhun.com/tv/dc',
    'https://www.iyouhun.com/tv/fty',
  ];

  /// 所有默认片源（首次启动时自动写入）
  static const defaultUrls = [...builtInUrls, ...thirdPartyUrls];

  /// 首次启动默认选中的源：跳过 Bridge（可能未启动）和第三方，挑第一个 CMS
  static const defaultSelectedUrl = 'https://jyzyapi.com/api.php/provide/vod/';

  /// 已知片源的友好名称和描述
  static const sourceInfo = <String, ({String name, String desc})>{
    'http://1.14.171.39:9978':
        (name: 'JAR Bridge', desc: '自建服务 · JAR 插件源'),
    'https://jyzyapi.com/api.php/provide/vod/':
        (name: '金鹰资源', desc: '双线路 · HD · 10万+'),
    'https://www.hongniuzy2.com/api.php/provide/vod/':
        (name: '红牛资源', desc: '双线路 · 10万+'),
    'https://bfzyapi.com/api.php/provide/vod/':
        (name: '暴风资源', desc: 'HD · 13万+ · 多CDN'),
    'https://www.tyyszy.com/api.php/provide/vod/':
        (name: '天一资源', desc: '多画质 · 75分类'),
    'https://collect.wolongzyw.com/api.php/provide/vod/':
        (name: '卧龙资源', desc: '8.5万+ · 54分类'),
    'https://api.apibdzy.com/api.php/provide/vod/':
        (name: '百度资源', desc: '老牌稳定 · 50分类'),
    // 多仓 / 第三方单仓
    'https://www.iyouhun.com/tv/dc':
        (name: '游魂多仓', desc: '多仓 · 27个子源'),
    'https://www.iyouhun.com/tv/fty':
        (name: '饭太硬', desc: '单仓 · 综合源'),
    'https://www.iyouhun.com/tv/fxz':
        (name: '分享者', desc: '单仓 · 画质高 · 速度慢'),
  };

  /// 根据 URL 获取友好名称，未知源从域名提取
  static String nameOf(String url) {
    final info = sourceInfo[url];
    if (info != null) return info.name;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.host.replaceAll('www.', '').split('.').first;
  }

  /// 根据 URL 获取描述信息
  static String? descOf(String url) => sourceInfo[url]?.desc;

  /// 判断是否为内置 CMS API 片源
  static bool isBuiltIn(String url) => builtInUrls.contains(url);

  late Box<String> _box;

  Future<void> init() async {
    _box = await Hive.openBox<String>(_boxName);
  }

  /// 获取所有已保存的配置源 URL
  /// 只返回 add() 写入的整数键条目，过滤掉 '_selected' 字符串键
  List<String> getAll() => _box.keys
      .whereType<int>()
      .map((k) => _box.get(k)!)
      .toList();

  /// 添加配置源 URL
  Future<void> add(String url) async {
    if (_box.values.contains(url)) return;
    await _box.add(url);
  }

  /// 删除配置源 URL
  Future<void> remove(String url) async {
    final key = _box.keys.firstWhere(
      (k) => _box.get(k) == url,
      orElse: () => null,
    );
    if (key != null) await _box.delete(key);
  }

  /// 获取当前选中的配置源 URL
  String? getSelected() => _box.get('_selected');

  /// 设置当前选中的配置源 URL
  Future<void> setSelected(String url) async {
    await _box.put('_selected', url);
  }

  /// 获取多仓源上次选中的仓库 URL
  String? getSelectedWarehouse(String sourceUrl) =>
      _box.get('_wh:$sourceUrl');

  /// 保存多仓源选中的仓库 URL
  Future<void> setSelectedWarehouse(
      String sourceUrl, String warehouseUrl) async {
    await _box.put('_wh:$sourceUrl', warehouseUrl);
  }

  /// 获取 Bridge 源上次选中的插件 key（null 表示"全部"或未记录过）
  String? getSelectedBridgePlugin(String sourceUrl) =>
      _box.get('_bp:$sourceUrl');

  /// 保存 Bridge 源选中的插件 key；传 null 表示"全部"（清除记录）
  Future<void> setSelectedBridgePlugin(
      String sourceUrl, String? key) async {
    if (key == null) {
      await _box.delete('_bp:$sourceUrl');
    } else {
      await _box.put('_bp:$sourceUrl', key);
    }
  }

  /// 初始化默认片源
  /// 首次启动写入全部默认源并选中第一个；
  /// 非首次启动补充新增的默认源（不影响已有数据和选中状态）
  Future<void> initDefaultsIfEmpty() async {
    final existing = getAll();
    if (existing.isEmpty) {
      // 首次启动
      for (final url in defaultUrls) {
        await add(url);
      }
      await setSelected(defaultSelectedUrl);
    } else {
      // 补充新增的默认源
      for (final url in defaultUrls) {
        if (!existing.contains(url)) {
          await add(url);
        }
      }
    }
  }
}
