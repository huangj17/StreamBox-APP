import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/source_health.dart';

import 'package:streambox/features/source/source_manage_page.dart';

void main() {
  testWidgets('排队与实际检测使用不同标签', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SourceHealthBadge(SourceHealth.queued()),
              SourceHealthBadge(SourceHealth.checking()),
            ],
          ),
        ),
      ),
    );
    expect(find.text('等待检测'), findsOneWidget);
    expect(find.text('检测中'), findsOneWidget);
  });

  testWidgets('片源列表展示不可用标记', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SourceHealthBadge(
              SourceHealth(
                status: SourceHealthStatus.unavailable,
                message: '播放域名已失效',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('不可用'), findsOneWidget);
  });
}
