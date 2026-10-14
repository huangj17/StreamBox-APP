import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/core/theme/app_theme.dart';
import 'package:streambox/features/update/app_update_controller.dart';
import 'package:streambox/features/update/app_update_widgets.dart';

import 'support/fake_app_updates.dart';

void main() {
  late FakeAppUpdateRepository repository;
  setUp(() => repository = FakeAppUpdateRepository());

  String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appUpdateRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          theme: AppTheme.dark,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppUpdateCard(),
              ),
            ),
          ),
        ),
      ),
    );
    FocusManager.instance.rootScope.descendants
        .singleWhere((node) => node.debugLabel == 'app-update-entry')
        .requestFocus();
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.enter);
  }

  testWidgets(
    'remote opens, reads long notes, moves between actions and restores entry focus',
    (tester) async {
      await open(tester);
      expect(focused(), 'app-update-primary');
      expect(find.text('下载更新'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(), 'app-update-notes');
      for (var i = 0; i < 5; i++) {
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(), 'app-update-close');
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(focused(), 'app-update-primary');
      final notesScroll = tester.state<ScrollableState>(
        find.byType(Scrollable).last,
      );
      expect(notesScroll.position.pixels, greaterThan(0));
      await key(tester, LogicalKeyboardKey.escape);
      expect(find.byType(AppUpdateDialog), findsNothing);
      expect(focused(), 'app-update-entry');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'download progress, cancellation and validation error keep a remote retry path',
    (tester) async {
      final pending = repository.pendingDownload = Completer<String>();
      await open(tester, size: const Size(960, 540));
      expect(
        tester
            .getRect(
              find.descendant(
                of: find.byType(AppUpdateDialog),
                matching: find.text('发现新版本 v0.4.1'),
              ),
            )
            .top,
        greaterThanOrEqualTo(24),
      );
      await key(tester, LogicalKeyboardKey.select);
      repository.progress!(512 * 1024);
      await tester.pumpAndSettle();
      expect(find.textContaining('50%'), findsOneWidget);
      expect(focused(), 'app-update-primary');
      await key(tester, LogicalKeyboardKey.select);
      expect(repository.downloadToken!.isCancelled, isTrue);
      pending.complete('/updates/cancelled.apk');
      await tester.pumpAndSettle();
      repository.pendingDownload = null;
      repository.verifyError = PlatformException(
        code: 'UPDATE_INVALID_APK',
        message: '安装包签名不匹配',
      );
      await key(tester, LogicalKeyboardKey.enter);
      expect(
        find.descendant(
          of: find.byType(AppUpdateDialog),
          matching: find.text('安装包签名不匹配'),
        ),
        findsOneWidget,
      );
      expect(find.text('重新下载'), findsOneWidget);
      expect(focused(), 'app-update-primary');
      repository.verifyError = null;
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('安装更新'), findsOneWidget);
      expect(focused(), 'app-update-primary');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focused(), 'app-update-entry');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'system authorization resumes installation and restores dialog focus after cancellation',
    (tester) async {
      repository.permission = false;
      await open(tester);
      await key(tester, LogicalKeyboardKey.enter);
      await key(tester, LogicalKeyboardKey.enter);
      expect(find.text('前往授权'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.enter);
      expect(repository.settingsCount, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      repository.permission = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(repository.installCount, 1);
      expect(
        find.descendant(
          of: find.byType(AppUpdateDialog),
          matching: find.textContaining('已取消安装'),
        ),
        findsOneWidget,
      );
      expect(focused(), 'app-update-primary');
      await key(tester, LogicalKeyboardKey.escape);
      expect(focused(), 'app-update-entry');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'compact touch and remote actions remain visible at width $width with large text',
      (tester) async {
        await open(tester, size: Size(width, 844), textScale: 1.3);
        await key(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'app-update-close');
        await key(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'app-update-primary');
        await tester.ensureVisible(find.text('下载更新'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载更新'));
        await tester.pumpAndSettle();
        expect(find.text('安装更新'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await key(tester, LogicalKeyboardKey.escape);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
