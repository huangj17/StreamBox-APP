import 'dart:convert';
import 'dart:io';
import 'package:streambox/data/models/official_source_catalog.dart';

/// Run from client/: dart run tool/validate_sources.dart ../deploy/streambox/sources.json
void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('用法：dart run tool/validate_sources.dart <sources.json>');
    exitCode = 64;
    return;
  }
  try {
    final file = File(args.single);
    if (file.lengthSync() > 256 * 1024) {
      throw const FormatException('配置文件不能超过 256 KiB');
    }
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('配置必须是 JSON 对象');
    }
    final catalog = OfficialSourceCatalog.fromJson(raw);
    stdout.writeln(
      '有效配置：${catalog.version}，${catalog.config.sites.length} 个片源',
    );
    for (final site in catalog.config.sites) {
      stdout.writeln(
        '${site.isEnabled ? '启用' : '停用'} · ${site.name} · ${site.api}',
      );
    }
  } catch (error) {
    stderr.writeln('校验失败：$error');
    exitCode = 1;
  }
}
