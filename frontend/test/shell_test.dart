import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/theme/theme.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/features/control/control_page.dart';
import 'package:uniconsole/features/devices/devices_page.dart';
import 'package:uniconsole/features/settings/settings_page.dart';
import 'package:uniconsole/main.dart';

Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  required double width,
  double height = 900,
  String location = Routes.devices,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // 容器由 ProviderScope 持有：卸载界面即释放，mock 的定时器随之停止。
  await tester.pumpWidget(
    ProviderScope(child: UniConsoleApp(initialLocation: location)),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(UniConsoleApp)));
}

/// 检查器容器（滚出视口时语义节点会被裁掉，所以按 widget 查找）。
final inspectorFinder = find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == '设备详情',
);

AppColors colorsOf(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold).first))
        .extension<AppColors>()!;

void main() {
  group('断点（§11）', () {
    testWidgets('≥ 1280：完整侧边栏 + 右栏在右侧', (tester) async {
      await pumpApp(tester, width: 1440);
      final sidebar = tester.widget<AppSidebar>(find.byType(AppSidebar));
      expect(sidebar.compact, isFalse);
      expect(find.byType(MobileTabBar), findsNothing);
      // 右栏与工具栏并排：右栏顶部与工具栏顶部同高，且在工具栏右边。
      final inspector = tester.getRect(inspectorFinder);
      final toolbar = tester.getRect(find.byType(AppToolbar));
      expect(inspector.left, greaterThanOrEqualTo(toolbar.right - 1));
      expect(inspector.width, AppSizes.inspectorWidth);
      expect(tester.takeException(), isNull);
    });

    testWidgets('900–1280：右栏堆到内容下方', (tester) async {
      await pumpApp(tester, width: 1000);
      expect(
        tester.widget<AppSidebar>(find.byType(AppSidebar)).compact,
        isFalse,
      );
      final toolbar = tester.getRect(find.byType(AppToolbar));
      final inspector = tester.getRect(inspectorFinder);
      expect(inspector.top, greaterThan(toolbar.bottom));
      expect(inspector.left, lessThan(toolbar.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets('600–900：64px 图标栏', (tester) async {
      await pumpApp(tester, width: 760);
      final sidebar = tester.widget<AppSidebar>(find.byType(AppSidebar));
      expect(sidebar.compact, isTrue);
      expect(
        tester.getSize(find.byType(AppSidebar)).width,
        AppSizes.sidebarRailWidth,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('< 600：隐藏侧边栏，显示底部标签栏', (tester) async {
      await pumpApp(tester, width: 390, height: 844);
      expect(find.byType(AppSidebar), findsNothing);
      expect(find.byType(MobileTabBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('侧边栏计数来自数据层：告警 2、联调 1、控制权 1、分组 3/3/2', (tester) async {
    await pumpApp(tester, width: 1440);
    final sidebar = tester.widget<AppSidebar>(find.byType(AppSidebar));
    final items = {
      for (final s in sidebar.sections)
        for (final i in s.items) i.id: i,
    };
    expect(items['alerts']!.badge, 2);
    expect(items['fleet']!.count, 1);
    expect(items['leases']!.count, 1);
    expect(items['group:patrol']!.count, 3);
    expect(items['group:rnd']!.count, 3);
    expect(items['group:showroom']!.count, 2);
    // 统计卡和侧边栏用同一数据源。
    expect(find.text('8'), findsWidgets);
  });

  testWidgets('点击侧边栏切换页面并更新选中项', (tester) async {
    await pumpApp(tester, width: 1440);
    expect(find.byType(DevicesPage), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('^告警中心')));
    await tester.pumpAndSettle();
    expect(find.text('「告警中心」将在第 5 阶段实现'), findsOneWidget);
    expect(
      tester.widget<AppSidebar>(find.byType(AppSidebar)).selectedId,
      'alerts',
    );

    await tester.tap(find.bySemanticsLabel('单机操控'));
    // 操控页持续推送遥测，不能 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 默认打开当前用户正在使用的设备 Alpha。
    expect(find.byType(ControlPage), findsOneWidget);
    expect(
      tester.widget<ControlPage>(find.byType(ControlPage)).deviceId,
      'go2-01',
    );
    expect(
      tester.widget<AppSidebar>(find.byType(AppSidebar)).selectedId,
      'control',
    );
    // 离开操控页，停止遥测订阅。
    await tester.tap(find.bySemanticsLabel(RegExp('^设备总览')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('设备分组跳转到带筛选的设备总览', (tester) async {
    await pumpApp(tester, width: 1440);
    await tester.tap(find.bySemanticsLabel(RegExp('^展厅')));
    await tester.pumpAndSettle();
    expect(find.text('分组「展厅」· 2 台设备'), findsOneWidget);
    expect(
      tester.widget<AppSidebar>(find.byType(AppSidebar)).selectedId,
      'group:showroom',
    );
  });

  testWidgets('设置 › 外观：切换深色与强调色', (tester) async {
    await pumpApp(tester, width: 1440, location: Routes.settings);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(colorsOf(tester).isDark, isFalse);

    await tester.tap(find.bySemanticsLabel('深色'));
    await tester.pumpAndSettle();
    expect(colorsOf(tester).isDark, isTrue);
    expect(colorsOf(tester).accentFill, const Color(0xFF0071E3));

    await tester.tap(find.bySemanticsLabel('橙色'));
    await tester.pumpAndSettle();
    final c = colorsOf(tester);
    expect(c.accent, AccentSwatch.orange.dark);
    expect(Contrast.ratio(c.onAccent, c.accentFill), greaterThanOrEqualTo(4.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('移动端标签栏：告警徽标、切换到「我的」', (tester) async {
    await pumpApp(tester, width: 390, height: 844);
    final bar = tester.widget<MobileTabBar>(find.byType(MobileTabBar));
    expect(bar.items.firstWhere((t) => t.id == 'alerts').badge, 2);
    expect(bar.selectedId, 'devices');

    await tester.tap(find.bySemanticsLabel('我的'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MobileTabBar>(find.byType(MobileTabBar)).selectedId,
      'me',
    );
    expect(find.text('更多功能'), findsOneWidget);
  });

  testWidgets('移动端大标题：滚动后收起为居中标题栏（§12）', (tester) async {
    await pumpApp(tester, width: 390, height: 844, location: Routes.gallery);

    double opacityOf(Finder f) {
      final o = tester.widget<AnimatedOpacity>(
        find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).first,
      );
      return o.opacity;
    }

    // 展开：只有大标题可见，标题栏里的小标题透明。
    final titles = find.text('组件');
    expect(titles, findsNWidgets(2));
    expect(opacityOf(titles.first), 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(opacityOf(find.text('组件').first), 1);
    expect(tester.takeException(), isNull);
  });
}
