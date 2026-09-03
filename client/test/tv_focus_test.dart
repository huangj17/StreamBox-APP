import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/widgets/tv_focus.dart';

void main() {
  late FocusNode button;
  late FocusNode elsewhere;
  var activations = 0;
  var longActivations = 0;

  Future<void> pumpButtons(WidgetTester tester) async {
    button = FocusNode();
    elsewhere = FocusNode();
    activations = 0;
    longActivations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TvFocusable(
                focusNode: button,
                autofocus: true,
                onActivate: () => activations++,
                onLongActivate: () => longActivations++,
                builder: (_, focused) => const Text('播放'),
              ),
              Focus(focusNode: elsewhere, child: const Text('其他控件')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      button.dispose();
      elsewhere.dispose();
    });
  }

  testWidgets('在别处按下确认、返回按钮后松开不会激活', (tester) async {
    await pumpButtons(tester);
    elsewhere.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    button.requestFocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    expect(activations, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activations, 1);
  });

  testWidgets('按住确认期间丢失焦点取消激活与长按，回来松键不会误触', (tester) async {
    await pumpButtons(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    elsewhere.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(longActivations, 0);
    button.requestFocus();
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(activations, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activations, 1);
  });

  testWidgets('长按只执行长按动作，短按与重复事件只激活一次', (tester) async {
    await pumpButtons(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.gameButtonA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.gameButtonA);
    expect(longActivations, 1);
    expect(activations, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.numpadEnter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.numpadEnter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.numpadEnter);
    expect(activations, 1);
    expect(longActivations, 1);
  });
}
