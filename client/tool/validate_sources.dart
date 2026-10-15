import 'dart:io';

/// Run from client/: dart run tool/validate_sources.dart ../deploy/streambox/sources.json
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('用法：dart run tool/validate_sources.dart <sources.json>');
    exitCode = 64;
    return;
  }
  // Site uses Flutter platform detection. Run the real parser in the Flutter
  // test runtime so this command also works when dart:ui is required.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final executable = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final flutter = flutterRoot == null
      ? executable
      : '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}$executable';
  try {
    final process = await Process.start(
      flutter,
      [
        'test',
        '--no-pub',
        '--reporter',
        'expanded',
        'tool/validate_sources_test.dart',
      ],
      environment: {
        'STREAMBOX_VALIDATE_SOURCES_PATH': File(args.single).absolute.path,
      },
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
  } on ProcessException catch (error) {
    stderr.writeln('无法启动 Flutter 校验：$error');
    exitCode = 69;
  }
}
