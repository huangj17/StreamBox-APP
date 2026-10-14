import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/features/source/providers/source_provider.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/settings/settings_screen.dart';
import 'package:streambox/features/update/app_update_controller.dart';
import 'package:streambox/features/update/app_update_widgets.dart';

import 'support/fake_app_updates.dart';

void main() {
  late Directory directory;
  late SourceStorage storage;
  late FakeAppUpdateRepository repository;
  late Dio dio;
  late SourceLibraryNotifier library;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-settings-');
    Hive.init(directory.path);
    storage = SourceStorage();
    await storage.init();
    repository = FakeAppUpdateRepository();
    dio = Dio();
    library = _Library(storage, SourceParser(dio));
  });

  tearDown(() async {
    dio.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'settings sidebar reaches update entry by remote and restores both navigation levels',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sourceStorageProvider.overrideWithValue(storage),
            sourceLibraryProvider.overrideWith((ref) => library),
            appUpdateRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'settings-nav-about',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'app-update-entry',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdateDialog), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'app-update-primary',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'app-update-entry',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'settings-nav-about',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _Library extends SourceLibraryNotifier {
  _Library(super.storage, super.parser);

  @override
  Future<void> restore() async {}
}
