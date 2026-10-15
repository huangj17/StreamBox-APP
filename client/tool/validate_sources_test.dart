import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/official_source_catalog.dart';

void main() {
  test('校验官方配置源目录', () {
    final path = Platform.environment['STREAMBOX_VALIDATE_SOURCES_PATH'];
    if (path == null) {
      throw const FormatException(
        '请通过 dart run tool/validate_sources.dart <sources.json> 运行',
      );
    }
    final file = File(path);
    if (file.lengthSync() > 256 * 1024) {
      throw const FormatException('配置文件不能超过 256 KiB');
    }
    final catalog = OfficialSourceCatalog.fromJson(
      jsonDecode(file.readAsStringSync()),
    );
    stdout.writeln(
      '有效配置：${catalog.version}，${catalog.groups.length} 个配置源，${catalog.config.sites.length} 个内嵌片源',
    );
    for (final group in catalog.groups) {
      stdout.writeln(
        '${group.title} · ${group.isInline ? '${group.config!.sites.length} 个内嵌片源' : group.url}',
      );
    }
    for (final site in catalog.config.sites) {
      stdout.writeln(
        '${!site.isSupported
            ? '暂不兼容（不会请求）'
            : site.isEnabled
            ? '启用'
            : '停用'} · ${site.name} · ${site.api}',
      );
    }
  });
}
