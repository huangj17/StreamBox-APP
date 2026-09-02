import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/data/local/source_storage.dart';

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

  test('新安装只提供保留的两个 CMS 源', () async {
    await storage.initDefaultsIfEmpty();

    expect(storage.getAll(), [
      'https://bfzyapi.com/api.php/provide/vod/',
      'https://www.hongniuzy2.com/api.php/provide/vod/',
    ]);
    expect(storage.getSelected(), SourceStorage.defaultSelectedUrl);
  });

  test('升级清理所有旧第三方、失效 CMS 和 JAR 源以及关联记录', () async {
    const removedUrls = [
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
    for (final url in [...SourceStorage.builtInUrls, ...removedUrls]) {
      await storage.add(url);
      await storage.setSelectedWarehouse(url, 'https://warehouse.example');
      await storage.setSelectedBridgePlugin(url, 'plugin');
    }
    await storage.setSelected(removedUrls.first);

    await storage.initDefaultsIfEmpty();
    await Hive.close();
    await storage.init();
    await storage.initDefaultsIfEmpty();

    expect(storage.getAll(), SourceStorage.builtInUrls);
    expect(storage.getSelected(), SourceStorage.defaultSelectedUrl);
    for (final url in [...SourceStorage.builtInUrls, ...removedUrls]) {
      expect(storage.getSelectedWarehouse(url), isNull);
      expect(storage.getSelectedBridgePlugin(url), isNull);
    }
  });

  test('保留仍有效的选中源，迁移后手动添加的配置不会在重启时被清空', () async {
    const retained = 'https://www.hongniuzy2.com/api.php/provide/vod/';
    await storage.add(retained);
    await storage.setSelected(retained);
    await storage.initDefaultsIfEmpty();
    expect(storage.getSelected(), retained);

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
