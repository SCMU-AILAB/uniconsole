import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/features/agent/intercom_widgets.dart';
import 'package:uniconsole/features/control/control_input.dart';
import 'package:uniconsole/features/devices/devices_page.dart';

import 'helpers.dart';

void main() {
  group('成员与权限', () {
    testWidgets('统计来自成员列表；按角色筛选', (tester) async {
      await open(tester, location: Routes.members);
      expect(find.text('5 名成员 · 4 种角色 · 审计日志保留 180 天'), findsOneWidget);
      expect(find.text('管理 Charlie、Delta · 授权 Alpha'), findsOneWidget);
      expect(find.text('展厅设备 · 仅视频'), findsOneWidget);

      await tapText(tester, '使用者');
      expect(find.text('陈一'), findsOneWidget);
      expect(find.text('林悦'), findsNothing);
      await close(tester);
    });

    testWidgets('编辑成员：改为观察者并写入审计日志', (tester) async {
      final container = await open(tester, location: Routes.members);
      await tester.tap(find.widgetWithText(SecondaryButton, '编辑').at(3));
      await settle(tester);
      expect(find.text('编辑 陈一'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedControl<MemberRole>),
          matching: find.text('观察者'),
        ),
      );
      await settle(tester);
      await tapText(tester, '保存');
      final m = container
          .read(membersProvider)
          .value!
          .firstWhere((m) => m.id == 'chenyi');
      expect(m.role, MemberRole.viewer);
      expect(
        container.read(auditProvider).value!.first.action,
        startsWith('将 陈一 设为观察者'),
      );
      expect(find.text('已保存 陈一 的权限'), findsOneWidget);
      await close(tester);
    });

    testWidgets('邀请成员后成员数随之变化', (tester) async {
      await open(tester, location: Routes.members);
      await tapText(tester, '邀请成员');
      await tester.enterText(find.byType(EditableText).at(0), '王五');
      await tester.enterText(find.byType(EditableText).at(1), 'wangwu');
      await settle(tester);
      await tester.tap(find.text('邀请').last);
      await settle(tester);
      expect(find.text('6 名成员 · 4 种角色 · 审计日志保留 180 天'), findsOneWidget);
      expect(find.text('王五'), findsOneWidget);
      await close(tester);
    });
  });

  group('智能体与对讲', () {
    testWidgets('执行计划 → 执行中 → 中止并停止所有设备', (tester) async {
      final container = await open(tester, location: Routes.agent);
      expect(find.text('等待确认'), findsOneWidget);
      await tester.tap(find.widgetWithText(PrimaryButton, '执行计划'));
      await settle(tester);
      expect(find.text('执行中 · 第 1/4 步'), findsOneWidget);
      expect(
        container.read(deviceProvider('go2-02'))!.status,
        DeviceStatus.busy,
      );
      await tapText(tester, '中止并停止所有设备');
      expect(find.text('已中止'), findsOneWidget);
      expect(
        container.read(deviceProvider('go2-02'))!.status,
        DeviceStatus.online,
      );
      await close(tester);
    });

    testWidgets('建议指令生成回桩计划；「修改」把原指令放回输入框', (tester) async {
      await open(tester, location: Routes.agent);
      await tapText(tester, '所有设备回桩充电');
      await settle(tester);
      expect(find.text('回桩计划 · 5 台'), findsOneWidget);
      // 新计划等待确认，旧计划仍等待确认：点最后一个「修改」。
      await tester.tap(find.text('修改').first);
      await settle(tester);
      expect(find.text('已取消'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, '所有设备回桩充电');
      await close(tester);
    });

    testWidgets('按住说话：按下讲话，松开结束', (tester) async {
      await open(tester, location: Routes.agent);
      expect(find.text('对象：Alpha · 延迟约 120 ms'), findsOneWidget);
      final g = await tester.startGesture(
        tester.getCenter(find.byType(TalkButton)),
      );
      await settle(tester);
      expect(find.text('正在讲话'), findsOneWidget);
      await g.up();
      await settle(tester);
      expect(find.text('按住说话'), findsOneWidget);
      await close(tester);
    });

    testWidgets('手机：确认执行；切到对讲选择对象并播报', (tester) async {
      final container = await open(
        tester,
        location: Routes.agent,
        width: 390,
        height: 844,
      );
      expect(find.text('确认执行'), findsOneWidget);
      await tapText(tester, '对讲');
      await tapText(tester, 'Bravo');
      expect(find.text('Bravo · 延迟约 120 ms'), findsOneWidget);
      await tapText(tester, '播报预设');
      await tapText(tester, '此区域禁止进入');
      expect(find.text('已播报「此区域禁止进入」到 Bravo（1 台）'), findsOneWidget);
      final events = await tester.runAsync(
        () => container
            .read(deviceRepositoryProvider)
            .watchEvents('go2-02')
            .first,
      );
      expect(events!.first.text, 'Kanade 播报：「此区域禁止进入」');
      await close(tester);
    });
  });

  group('设置', () {
    testWidgets('类别写在地址里；修改偏好立即生效', (tester) async {
      final container = await open(tester, location: Routes.settings);
      expect(find.text('操控时保持深色'), findsOneWidget);
      await tapText(tester, '大');
      expect(
        container.read(preferencesProvider).sidebarIconSize,
        SidebarIconSize.large,
      );
      await tester.tap(find.bySemanticsLabel('操控时保持深色').last);
      await settle(tester);
      expect(container.read(preferencesProvider).darkWhileControlling, isFalse);

      await tapText(tester, '控制与手柄');
      expect(find.text('Xbox 无线控制器'), findsOneWidget);
      // 「站立」改绑到 B：与原来的「趴下」互换。
      await tester.ensureVisible(find.text('重新绑定').at(2));
      await tester.tap(find.text('重新绑定').at(2));
      await settle(tester);
      await tester.tap(find.widgetWithText(MenuItemButton, 'B'));
      await settle(tester);
      final b = container.read(preferencesProvider).bindings;
      expect(b.firstWhere((x) => x.action == '站立').control, 'B');
      expect(b.firstWhere((x) => x.action == '趴下').control, 'A');
      await close(tester);
    });

    testWidgets('手机：类别列表 → 进入通知', (tester) async {
      await open(tester, location: Routes.settings, width: 390, height: 844);
      await tapText(tester, '通知');
      await settle(tester);
      expect(find.text('严重告警'), findsOneWidget);
      expect(find.text('横幅 + 声音 + 突破专注模式'), findsOneWidget);
      await close(tester);
    });

    test('摇杆死区与响应曲线', () {
      expect(
        shapeStick(const Offset(0.05, 0), 0.1, ResponseCurve.linear),
        Offset.zero,
      );
      expect(
        shapeStick(const Offset(0, 1), 0.1, ResponseCurve.linear).dy,
        closeTo(1, 1e-9),
      );
      expect(
        shapeAxis(-0.55, 0.1, ResponseCurve.exponential),
        closeTo(-0.25, 1e-9),
      );
    });

    testWidgets('⌘K 命令面板：搜索设备并回车打开', (tester) async {
      await open(tester, location: Routes.members);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Bravo');
      await settle(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      // 桌面宽度下是设备总览并选中该设备。
      expect(find.byType(DevicesPage), findsOneWidget);
      await close(tester);
    });
  });

  for (final width in [1440.0, 1000.0, 760.0, 390.0]) {
    testWidgets('第 6 阶段页面在 ${width.toInt()} 宽下无溢出', (tester) async {
      for (final loc in [
        Routes.members,
        Routes.agent,
        '/agent?mode=talk',
        Routes.settings,
        '/settings/pad',
        '/settings/keys',
        '/settings/net',
        '/settings/notify',
        '/settings/account',
      ]) {
        await open(tester, location: loc, width: width, height: 900);
        expect(tester.takeException(), isNull, reason: loc);
        await close(tester);
      }
    });
  }
}
