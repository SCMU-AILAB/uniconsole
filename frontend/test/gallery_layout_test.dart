import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/main.dart';

/// 在多种窗口宽度、两种外观下渲染组件预览页，确保没有溢出或异常（§10 布局切换）。
void main() {
  for (final width in [1440.0, 1000.0, 760.0, 390.0]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('预览页 ${width.toInt()} 宽 · ${mode.name}', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          const ProviderScope(
            child: UniConsoleApp(initialLocation: Routes.gallery),
          ),
        );
        ProviderScope.containerOf(tester.element(find.byType(UniConsoleApp)))
            .read(themeModeProvider.notifier)
            .set(mode);
        await tester.pumpAndSettle();

        // 逐屏滚到底，让所有区块都完成布局。主内容区是最大的那个纵向滚动视图。
        final scrollable = find
            .byType(Scrollable)
            .evaluate()
            .map((e) => e.widget as Scrollable)
            .where((s) => s.axisDirection == AxisDirection.down)
            .toList();
        final main = find.byWidget(scrollable.last);
        for (var i = 0; i < 40; i++) {
          await tester.drag(main, const Offset(0, -800), warnIfMissed: false);
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
