import 'dart:convert';
import 'dart:io';
import 'package:streambox/data/models/live_source_catalog.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      '用法：dart run tool/validate_live_sources.dart <live_sources.json>',
    );
    exitCode = 64;
    return;
  }
  try {
    final file = File(args.single);
    if (file.lengthSync() > 256 * 1024) {
      throw const FormatException('直播配置不能超过 256 KiB');
    }
    final catalog = LiveSourceCatalog.fromJson(
      jsonDecode(file.readAsStringSync()),
    );
    stdout.writeln('有效直播配置：${catalog.subscriptions.length} 个订阅');
    for (final item in catalog.subscriptions) {
      stdout.writeln(
        '${item.isEnabled ? '启用' : '停用'} · ${item.id} · ${item.name} · ${item.url}',
      );
    }
  } catch (error) {
    stderr.writeln('校验失败：$error');
    exitCode = 1;
  }
}
