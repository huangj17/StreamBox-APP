import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/core/config/app_updates.dart';
import 'package:streambox/data/models/app_release.dart';
import 'package:streambox/data/updates/app_update_repository.dart';
import 'package:streambox/features/update/app_update_controller.dart';

import 'support/fake_app_updates.dart';

Map<String, dynamic> manifest({List<int> bytes = const [1, 2, 3]}) => {
  'schemaVersion': 1,
  'packageName': 'com.streambox.streambox',
  'versionName': '0.4.1',
  'versionCode': 5,
  'downloadUrl': 'https://downloads.example/app.apk',
  'size': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  'certificateSha256': 'cd' * 32,
  'minSdk': 23,
  'releaseNotes': '支持 APK 升级',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manifest requires HTTPS and bounded, verifiable APK metadata', () {
    final valid = manifest();
    expect(AppRelease.fromJson(valid).versionCode, 5);
    for (final entry in <String, Object>{
      'schemaVersion': 2,
      'downloadUrl': 'http://downloads.example/app.apk',
      'versionCode': '5',
      'size': AppUpdates.maxApkBytes + 1,
      'sha256': 'bad',
      'certificateSha256': 'bad',
      'minSdk': 0,
    }.entries) {
      expect(
        () => AppRelease.fromJson({...valid, entry.key: entry.value}),
        throwsFormatException,
      );
    }
    expect(
      () => AppUpdates.requireHttps('https://user:password@example/app.apk'),
      throwsFormatException,
    );
  });

  group('update controller', () {
    late FakeAppUpdateRepository repository;
    late AppUpdateController controller;
    setUp(() {
      repository = FakeAppUpdateRepository();
      controller = AppUpdateController(repository);
    });
    tearDown(() => controller.dispose());

    test('does not download during the startup availability check', () async {
      await controller.check();
      expect(controller.state.phase, UpdatePhase.available);
      expect(repository.downloadCount, 0);
      await controller.download();
      expect(controller.state.phase, UpdatePhase.ready);
      expect(repository.verifyCount, 1);
      expect(repository.installCount, 0);
    });

    test('invalid APK cannot reach installation and is removed', () async {
      await controller.check();
      repository.verifyError = PlatformException(
        code: 'UPDATE_INVALID_APK',
        message: '签名不匹配',
      );
      await controller.download();
      await controller.install();
      expect(controller.state.phase, UpdatePhase.error);
      expect(controller.state.apkPath, isNull);
      expect(repository.installCount, 0);
      expect(repository.removed, ['/updates/verified.apk']);
    });

    test('cancelled download cannot overwrite a subsequent retry', () async {
      await controller.check();
      final pending = repository.pendingDownload = Completer<String>();
      final first = controller.download();
      controller.cancelTransfer();
      expect(repository.downloadToken!.isCancelled, isTrue);
      repository.pendingDownload = null;
      await controller.download();
      pending.complete('/updates/stale.apk');
      await first;
      expect(controller.state.apkPath, '/updates/verified.apk');
      expect(repository.removed, ['/updates/stale.apk']);
    });

    test(
      'returns from permission settings to one user-requested installation',
      () async {
        await controller.check();
        await controller.download();
        repository.permission = false;
        await controller.install();
        expect(controller.state.phase, UpdatePhase.permissionRequired);
        await controller.openPermissionSettings();
        await controller.resumed();
        expect(controller.state.phase, UpdatePhase.permissionRequired);
        expect(repository.installCount, 0);
        await controller.openPermissionSettings();
        repository.permission = true;
        await controller.resumed();
        await controller.resumed();
        expect(repository.installCount, 1);
        expect(controller.state.phase, UpdatePhase.ready);
        expect(controller.state.status, contains('取消安装'));
      },
    );

    test('check cancellation ignores stale results and allows retry', () async {
      final pending = repository.pendingCheck = Completer<UpdateCheckResult>();
      final first = controller.check();
      controller.cancelTransfer();
      repository.pendingCheck = null;
      repository.result = const UpdateCheckResult('0.4.1', null);
      await controller.check();
      pending.complete(UpdateCheckResult('0.4.0', testRelease));
      await first;
      expect(controller.state.phase, UpdatePhase.current);
      expect(controller.state.release, isNull);
    });

    test(
      'a cached APK rejected at installation is removed and can be downloaded again',
      () async {
        await controller.check();
        await controller.download();
        repository.installError = PlatformException(
          code: 'UPDATE_INVALID_APK',
          message: '安装包已失效',
        );
        await controller.install();
        expect(controller.state.apkPath, isNull);
        expect(controller.state.phase, UpdatePhase.error);
        expect(repository.removed, ['/updates/verified.apk']);
        await controller.download();
        expect(controller.state.phase, UpdatePhase.ready);
        expect(repository.downloadCount, 2);
      },
    );

    test(
      'closing the dialog cancels a pending authorization continuation',
      () async {
        await controller.check();
        await controller.download();
        repository.permission = false;
        await controller.install();
        await controller.openPermissionSettings();
        controller.leaveDialog();
        repository.permission = true;
        await controller.resumed();
        expect(repository.installCount, 0);
      },
    );

    test('other platforms do not fetch updates', () async {
      controller.dispose();
      repository.supported = false;
      controller = AppUpdateController(repository);
      await controller.check();
      expect(repository.checkCount, 0);
    });
  });

  group('download and verification transport', () {
    late Directory directory;
    late _Adapter adapter;
    late AndroidAppUpdateRepository repository;
    const channel = MethodChannel('com.streambox/updates');
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('apk-updates-');
      adapter = _Adapter();
      final dio = Dio()..httpClientAdapter = adapter;
      repository = AndroidAppUpdateRepository(
        dio: dio,
        manifestUrl: 'https://updates.example/update.json',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'deviceInfo') {
              return {
                'packageName': 'com.streambox.streambox',
                'versionName': '0.4.0',
                'versionCode': 4,
                'sdkInt': 30,
                'certificates': ['cd' * 32],
                'cacheDirectory': directory.path,
              };
            }
            return null;
          });
      adapter.responses['https://updates.example/update.json'] = () =>
          ResponseBody.fromString(jsonEncode(manifest()), 200);
      adapter.responses['https://downloads.example/app.apk'] = () =>
          ResponseBody.fromBytes([1, 2, 3], 200);
    });
    tearDown(() async {
      repository.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await directory.delete(recursive: true);
    });

    test(
      'streams APK bytes, validates hash and returns a complete private file',
      () async {
        final release = (await repository.check(CancelToken())).release!;
        final progress = <int>[];
        final path = await repository.download(
          release,
          CancelToken(),
          progress.add,
        );
        expect(await File(path).readAsBytes(), [1, 2, 3]);
        expect(path, endsWith('/update.apk'));
        expect(progress.last, 3);
        await repository.remove(path);
        expect(directory.listSync(), isEmpty);
      },
    );

    test(
      'rejects wrong hashes, truncated and oversized chunked bodies and cleans partials',
      () async {
        final release = (await repository.check(CancelToken())).release!;
        for (final body in [
          [1, 2, 4],
          [1, 2],
          [1, 2, 3, 4],
        ]) {
          adapter.responses['https://downloads.example/app.apk'] = () =>
              ResponseBody.fromBytes(body, 200);
          await expectLater(
            repository.download(release, CancelToken(), (_) {}),
            throwsFormatException,
          );
          expect(directory.listSync(), isEmpty);
        }
      },
    );

    test('cancel interrupts transfer and cleans the owned directory', () async {
      final release = (await repository.check(CancelToken())).release!;
      final token = CancelToken();
      adapter.responses['https://downloads.example/app.apk'] = () =>
          ResponseBody(
            Stream.fromIterable([
              Uint8List.fromList([1]),
              Uint8List.fromList([2, 3]),
            ]),
            200,
          );
      await expectLater(
        repository.download(release, token, (_) => token.cancel()),
        throwsA(isA<DioException>()),
      );
      expect(directory.listSync(), isEmpty);
    });

    test(
      'refuses HTTPS to HTTP redirects before requesting the destination',
      () async {
        final release = (await repository.check(CancelToken())).release!;
        adapter.responses['https://downloads.example/app.apk'] = () =>
            ResponseBody.fromString(
              '',
              302,
              headers: {
                'location': ['http://unsafe.example/app.apk'],
              },
            );
        await expectLater(
          repository.download(release, CancelToken(), (_) {}),
          throwsFormatException,
        );
        expect(
          adapter.requested,
          isNot(contains('http://unsafe.example/app.apk')),
        );
        expect(directory.listSync(), isEmpty);
      },
    );

    test(
      'rejects a different package, incompatible SDK and mismatched release certificate',
      () async {
        for (final change in [
          {'packageName': 'other.app'},
          {'minSdk': 31},
          {'certificateSha256': 'ef' * 32},
        ]) {
          adapter.responses['https://updates.example/update.json'] = () =>
              ResponseBody.fromString(
                jsonEncode({...manifest(), ...change}),
                200,
              );
          await expectLater(
            repository.check(CancelToken()),
            throwsFormatException,
          );
        }
      },
    );
  });
}

class _Adapter implements HttpClientAdapter {
  final responses = <String, ResponseBody Function()>{};
  final requested = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    return responses[options.uri.toString()]!();
  }

  @override
  void close({bool force = false}) {}
}
