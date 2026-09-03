import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/official_source_catalog.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/source_config.dart';

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

  test('重复 Lite 订阅升级归入官方，保留缓存、其他订阅和 API 偏好，可手动恢复', () async {
    const lite = 'https://config.example/OuonnkiTV/lite.json';
    const other = 'https://custom.example/collection.json';
    const uniqueLite = 'https://unique.example/OuonnkiTV/lite.json';
    const api = 'https://a.example/api.php';
    final catalog = OfficialSourceCatalog.fromJson([
      {'id': 'a', 'name': '官方 A', 'url': api},
      {'id': 'b', 'name': '官方 B', 'url': 'https://b.example/api.php'},
    ]);
    final duplicate = SourceConfig(sites: [Site.fromUrl('$api/')]);
    for (final url in [lite, other]) {
      await storage.add(url);
      await storage.cacheConfig(url, duplicate);
    }
    await storage.add(uniqueLite);
    await storage.cacheConfig(
      uniqueLite,
      SourceConfig(sites: [Site.fromUrl('https://unique.example/api.php')]),
    );
    await storage.saveOfficialSnapshot(
      OfficialSourceSnapshot(catalog, DateTime.utc(2026, 9, 3)),
    );
    await storage.setSelected(lite);
    await storage.setSiteEnabled({api: false});
    await storage.setHomeSite(api);

    await storage.initDefaultsIfEmpty();
    await Hive.close();
    await storage.init();
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), [other, uniqueLite, SourceStorage.officialUrl]);
    expect(storage.getSelected(), SourceStorage.officialUrl);
    expect(storage.getSiteEnabled(), {api: false});
    expect(storage.getHomeSite(), api);
    expect(storage.getOfficialSnapshot()!.catalog.toJson(), catalog.toJson());
    expect(storage.getCachedConfig(lite)!.sites.single.identity, api);
    expect(Hive.box<String>('source_urls').get('_merged_lite:$lite'), lite);

    await storage.add(lite);
    await storage.setSelected(lite);
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), contains(lite));
    expect(storage.getSelected(), lite);
  });

  test('官方尚未缓存或明确清空时不移除 Lite，缓存可用后才安全迁移', () async {
    const lite = 'https://config.example/OuonnkiTV/lite.json';
    const api = 'https://a.example/api.php';
    await storage.add(lite);
    await storage.cacheConfig(lite, SourceConfig(sites: [Site.fromUrl(api)]));
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), contains(lite));
    await storage.saveOfficialSnapshot(
      OfficialSourceSnapshot(
        OfficialSourceCatalog.fromJson([]),
        DateTime.now(),
      ),
    );
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), contains(lite));
    await storage.saveOfficialSnapshot(
      OfficialSourceSnapshot(
        OfficialSourceCatalog.fromJson([
          {'id': 'a', 'name': 'A', 'url': api},
        ]),
        DateTime.now(),
      ),
    );
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), [SourceStorage.officialUrl]);
  });

  for (final selectCustom in [false, true]) {
    test('官方地址改回 HTTP IP，保留缓存、偏好和自定义订阅（选中自定义 $selectCustom）', () async {
      const oldUrl = 'https://stvbox.cloud/streambox/sources.json';
      const customUrl = 'https://custom.example/config.json';
      const sameServerCustomUrl = 'http://1.14.171.39/custom.json';
      const sameDomainCustomUrl = 'https://stvbox.cloud/custom.json';
      await Hive.box<String>(
        'source_urls',
      ).put('_official_sources_migrated_v1', '1');
      // The previous HTTPS migration has already run on installed clients.
      await Hive.box<String>(
        'source_urls',
      ).put('_official_sources_https_migrated_v1', '1');
      for (final url in [
        oldUrl,
        customUrl,
        sameServerCustomUrl,
        sameDomainCustomUrl,
        SourceStorage.officialUrl,
      ]) {
        await storage.add(url);
      }
      await storage.setSelected(selectCustom ? customUrl : oldUrl);
      await storage.setSelectedWarehouse(
        customUrl,
        'https://custom.example/warehouse.json',
      );
      final catalog = OfficialSourceCatalog.fromJson([
        {
          'id': 'baofeng',
          'name': '暴风资源',
          'url': SourceStorage.builtInUrls.first,
        },
      ]);
      final syncedAt = DateTime.utc(2026, 9, 2);
      final home = catalog.config.sites.first.identity;
      await storage.saveOfficialSnapshot(
        OfficialSourceSnapshot(catalog, syncedAt),
      );
      await storage.setSiteEnabled({home: false});
      await storage.setHomeSite(home);

      await storage.initDefaultsIfEmpty();
      await Hive.close();
      await storage.init();
      await storage.initDefaultsIfEmpty();

      expect(storage.getAll(), [
        customUrl,
        sameServerCustomUrl,
        sameDomainCustomUrl,
        SourceStorage.officialUrl,
      ]);
      expect(
        storage.getSelected(),
        selectCustom ? customUrl : SourceStorage.officialUrl,
      );
      expect(
        storage.getSelectedWarehouse(customUrl),
        'https://custom.example/warehouse.json',
      );
      expect(storage.getOfficialSnapshot()!.catalog.toJson(), catalog.toJson());
      expect(storage.getOfficialSnapshot()!.syncedAt, syncedAt);
      expect(storage.getSiteEnabled(), {home: false});
      expect(storage.getHomeSite(), home);
    });
  }

  test('原 HTTP IP 订阅保持不变，迁移后手动重加 HTTPS 订阅不再被删除', () async {
    await storage.add(SourceStorage.officialUrl);
    await storage.setSelected(SourceStorage.officialUrl);
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), [SourceStorage.officialUrl]);
    expect(storage.getSelected(), SourceStorage.officialUrl);

    const oldUrl = 'https://stvbox.cloud/streambox/sources.json';
    await storage.add(oldUrl);
    await storage.setSelected(oldUrl);
    await Hive.close();
    await storage.init();
    await storage.initDefaultsIfEmpty();
    expect(storage.getAll(), [SourceStorage.officialUrl, oldUrl]);
    expect(storage.getSelected(), oldUrl);
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
