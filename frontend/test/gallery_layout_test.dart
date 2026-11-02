import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/main.dart';

/// 在三种窗口宽度、两种外观下渲染预览页，确保没有溢出或异常（§10 布局切换）。
void main() {
  for (final width in [1440.0, 1000.0, 760.0, 390.0]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('预览页 ${width.toInt()} 宽 · ${mode.name}', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(themeModeProvider.notifier).set(mode);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const UniConsoleApp(),
          ),
        );
        await tester.pumpAndSettle();

        // 逐屏滚到底，让所有区块都完成布局。
        final scrollable = find.byType(Scrollable).first;
        for (var i = 0; i < 40; i++) {
          await tester.drag(scrollable, const Offset(0, -800));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
