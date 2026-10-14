import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/local/source_storage.dart';
import 'package:streambox/data/models/live_source_catalog.dart';
import 'package:streambox/data/sources/source_parser.dart';
import 'package:streambox/features/home/providers/categories_provider.dart';
import 'package:streambox/features/live/providers/live_provider.dart';
import 'package:streambox/features/source/providers/source_library_provider.dart';
import 'package:streambox/features/update/app_update_controller.dart';
import 'package:streambox/main.dart';
import 'support/fake_app_updates.dart';
import 'support/fake_live.dart';

class _EmptySourceLibrary extends SourceLibraryNotifier {
  _EmptySourceLibrary() : super(SourceStorage(), SourceParser(Dio()));
  @override
  Future<void> restore() async {}
  @override
  void setForeground(bool foreground) {}
}

void main() {
  testWidgets(
    'Cold start syncs live catalog after root mounts without red screen',
    (tester) async {
      final storage = FakeLiveStorage()
        ..items = []
        ..selection = null;
      final pending = Completer<LiveSourceCatalog>();
      final repository = FakeLiveRepository()
        ..catalogResponse = () => pending.future;
      final library = _EmptySourceLibrary();
      final updates = FakeAppUpdateRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sourceLibraryProvider.overrideWith((_) => library),
            watchHistoryProvider.overrideWith((_) async => []),
            liveStorageProvider.overrideWithValue(storage),
            liveRepositoryProvider.overrideWithValue(repository),
            appUpdateRepositoryProvider.overrideWithValue(updates),
          ],
          child: const StreamBoxApp(),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(repository.catalogTokens, hasLength(1));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(StreamBoxApp)),
      );
      expect(container.read(liveProvider).catalogLoading, isTrue);
      expect(updates.checkCount, 1);
      expect(container.read(appUpdateProvider).phase, UpdatePhase.available);
      pending.complete(liveTestCatalog());
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(container.read(liveProvider).subscriptions, hasLength(3));
      expect(container.read(liveProvider).catalogError, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(repository.catalogTokens.single.isCancelled, isTrue);
    },
  );
}
