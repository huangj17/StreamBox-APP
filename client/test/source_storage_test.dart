import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/site.dart';

void main() {
  late Directory directory;
  late SourceStorage storage;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source-storage-test-');
    Hive.init(directory.path);
    storage = SourceStorage();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('新安装只保存官方订阅地址，不再写死独立 CMS 源', () async {
    await storage.initDefaultsIfEmpty();

    expect(storage.getAll(), [SourceStorage.officialUrl]);
    expect(storage.getSelected(), SourceStorage.defaultSelectedUrl);
  });

  test('升级仅迁移两个旧内置 URL，保留全部自定义源及关联记录', () async {
    const customUrls = [
      'https://www.iyouhun.com/tv/fxz',
      'https://www.iyouhun.com/tv/dc',
      'https://www.iyouhun.com/tv/fty',
      'https://www.tyyszy.com/api.php/provide/vod/',
      'https://collect.wolongzyw.com/api.php/provide/vod/',
      'https://api.apibdzy.com/api.php/provide/vod/',
      'https://jyzyapi.com/api.php/provide/vod/',
      'http://127.0.0.1:9978',
      'http://localhost:9978',
      'https://custom-bridge.example:9978',
      'https://timeout.example/config.json',
    ];
    for (final url in [...SourceStorage.builtInUrls, ...customUrls]) {
      await storage.add(url);
      await storage.setSelectedWarehouse(url, 'https://warehouse.example');
      await storage.setSelectedBridgePlugin(url, 'plugin');
    }
    await storage.setSelected(customUrls.first);

    await storage.initDefaultsIfEmpty();
    await Hive.close();
    await storage.init();
    await storage.initDefaultsIfEmpty();

    expect(storage.getAll(), [...customUrls, SourceStorage.officialUrl]);
    expect(storage.getSelected(), customUrls.first);
    for (final url in customUrls) {
      expect(storage.getSelectedWarehouse(url), 'https://warehouse.example');
      expect(storage.getSelectedBridgePlugin(url), 'plugin');
    }
  });

  test('保留仍有效的选中源，迁移后手动添加的配置不会在重启时被清空', () async {
    const retained = 'https://www.hongniuzy2.com/api.php/provide/vod/';
    await storage.add(retained);
    await storage.setSelected(retained);
    await storage.initDefaultsIfEmpty();
    expect(storage.getSelected(), SourceStorage.officialUrl);
    expect(storage.getHomeSite(), Site.canonicalApi(retained));

    const added = 'https://new.example/config.json';
    await storage.add(added);
    await storage.setSelected(added);
    await storage.setSelectedWarehouse(added, 'https://new.example/warehouse');
    await Hive.close();
    await storage.init();
    await storage.initDefaultsIfEmpty();

    expect(storage.getAll(), contains(added));
    expect(storage.getSelected(), added);
    expect(
      storage.getSelectedWarehouse(added),
      'https://new.example/warehouse',
    );
  });

  test('迁移完成后用户手动添加的原内置 API 不会再次被删除', () async {
    await storage.initDefaultsIfEmpty();
    await storage.add(SourceStorage.builtInUrls.first);
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), [
      SourceStorage.officialUrl,
      SourceStorage.builtInUrls.first,
    ]);
  });

  test('删除源时清理选中状态、仓库及插件记录，重启后不再恢复', () async {
    const removed = 'https://removed.example/config.json';
    const retained = 'https://retained.example/config.json';
    // 选中键可能比 URL 条目更早写入，删除时不能只匹配第一个值。
    await storage.setSelected(removed);
    await Hive.box<String>('source_urls').add(removed);
    await storage.add(retained);
    await storage.setSelectedWarehouse(removed, 'https://warehouse.example');
    await storage.setSelectedBridgePlugin(removed, 'plugin');

    await storage.remove(removed);
    await Hive.close();
    await storage.init();

    expect(storage.getAll(), [retained]);
    expect(storage.getSelected(), isNull);
    expect(storage.getSelectedWarehouse(removed), isNull);
    expect(storage.getSelectedBridgePlugin(removed), isNull);
  });
}
