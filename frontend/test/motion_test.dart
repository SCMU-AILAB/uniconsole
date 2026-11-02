import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/features/devices/devices_page.dart';
import 'package:uniconsole/main.dart';

Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  double width = 1440,
  double height = 900,
  String location = Routes.devices,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(themeModeProvider.notifier).set(ThemeMode.light);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: UniConsoleApp(initialLocation: location),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Widget _segmentedHarness(ValueNotifier<String> v) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(
    body: Center(
      child: ValueListenableBuilder(
        valueListenable: v,
        builder: (context, value, _) => SegmentedControl<String>(
          value: value,
          onChanged: (n) => v.value = n,
          options: const [
            SegmentOption('a', '全部'),
            SegmentOption('b', '在线'),
            SegmentOption('c', '告警'),
          ],
        ),
      ),
    ),
  ),
);

double _thumbLeft(WidgetTester tester) => tester
    .getTopLeft(
      find.descendant(
        of: find.byType(SegmentedControl<String>),
        matching: find.byType(AnimatedPositioned),
      ),
    )
    .dx;

void main() {
  group('弹簧曲线', () {
    test('snappy 轻微回弹、smooth 无回弹，结束时都落到 1', () {
      double peak(SpringCurve c) => List.generate(
        201,
        (i) => c.transform(i / 200),
      ).reduce((a, b) => a > b ? a : b);
      expect(peak(AppMotion.snappy), inInclusiveRange(1.0, 1.02));
      expect(peak(AppMotion.smooth), lessThanOrEqualTo(1.0005));
      expect(AppMotion.snappy.transform(1), 1);
      expect(
        AppMotion.snappy.settle.inMilliseconds,
        inInclusiveRange(300, 600),
      );
    });
  });

  testWidgets('侧边栏切换页面是瞬时的（不做转场）', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^告警中心')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(DevicesPage), findsNothing);
    expect(find.text('「告警中心」将在第 5 阶段实现'), findsOneWidget);
  });

  testWidgets('层级进入（push）以 iOS 推入动画滑入', (tester) async {
    await pumpApp(tester, width: 390, height: 844, location: Routes.me);
    await tester.tap(find.text('地图与任务'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final mid = tester.getTopLeft(find.text('「地图与任务」将在第 5 阶段实现')).dx;
    await tester.pumpAndSettle();
    final end = tester.getTopLeft(find.text('「地图与任务」将在第 5 阶段实现')).dx;
    expect(mid, greaterThan(end + 20), reason: '推入过程中页面应在右侧滑入');
    // 返回按钮出现。
    expect(find.bySemanticsLabel('返回'), findsOneWidget);
  });

  testWidgets('分段控件选中块以弹簧滑动到新位置', (tester) async {
    final v = ValueNotifier('a');
    await tester.pumpWidget(_segmentedHarness(v));
    final start = _thumbLeft(tester);
    await tester.tap(find.text('告警'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final mid = _thumbLeft(tester);
    await tester.pumpAndSettle();
    final end = _thumbLeft(tester);
    expect(end, greaterThan(start));
    expect(mid, greaterThan(start));
    expect(mid, lessThan(end));
  });

  testWidgets('减弱动态效果：选中块直接跳到新位置', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final v = ValueNotifier('a');
    await tester.pumpWidget(_segmentedHarness(v));
    await tester.tap(find.text('告警'));
    await tester.pump();
    final first = _thumbLeft(tester);
    await tester.pumpAndSettle();
    expect(first, _thumbLeft(tester));
  });

  testWidgets('浅色 → 深色是交叉淡化，而不是瞬间切换', (tester) async {
    final container = await pumpApp(tester);
    final light = AppColors.light.windowBackground;
    final dark = AppColors.dark.windowBackground;
    container.read(themeModeProvider.notifier).set(ThemeMode.dark);
    await tester.pump();
    await tester.pump(AppMotion.appearance ~/ 2);
    final mid = Theme.of(tester.element(find.byType(DevicesPage)))
        .extension<AppColors>()!
        .windowBackground;
    expect(mid, isNot(light));
    expect(mid, isNot(dark));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(DevicesPage)))
          .extension<AppColors>()!
          .windowBackground,
      dark,
    );
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.iOS,
  ]) {
    testWidgets('根页面与外壳没有转场遮罩：背景保持 token 原色（${platform.name}）', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await pumpApp(tester);
      final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
      final img = (await tester.runAsync(
        () => layer.toImage(const Rect.fromLTWH(0, 0, 1440, 900)),
      ))!;
      final bytes = (await tester.runAsync(
        () => img.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      Color at(int x, int y) {
        final i = (y * 1440 + x) * 4;
        return Color.fromARGB(
          255,
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }

      // 内容区底部空白处、侧边栏空白处。
      expect(at(600, 880), AppColors.light.windowBackground);
      expect(at(100, 830), AppColors.light.sidebarBackground);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
