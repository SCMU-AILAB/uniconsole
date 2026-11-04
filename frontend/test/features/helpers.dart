import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/data/mock/mock_repositories.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/main.dart';

/// 打开应用并逐帧推进（页面上有每秒刷新的倒计时，不能 pumpAndSettle）。
Future<ProviderContainer> open(
  WidgetTester tester, {
  required String location,
  double width = 1440,
  double height = 1200,
  bool signedIn = true,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // 容器由 ProviderScope 持有：卸载界面即释放，mock 的定时器随之停止。
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (!signedIn)
          mockWorldProvider.overrideWith((ref) {
            final world = MockWorld(signedIn: false);
            ref.onDispose(world.dispose);
            return world;
          }),
      ],
      child: UniConsoleApp(initialLocation: location),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(UniConsoleApp)),
  );
  container.read(themeModeProvider.notifier).set(ThemeMode.light);
  await settle(tester);
  return container;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> tapText(WidgetTester tester, String text) async {
  final f = find.text(text);
  await tester.ensureVisible(f.first);
  await tester.tap(f.first);
  await settle(tester);
}
