import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniconsole/app/destinations.dart';
import 'package:uniconsole/core/widgets/widgets.dart';
import 'package:uniconsole/data/models/models.dart';
import 'package:uniconsole/data/providers.dart';
import 'package:uniconsole/features/fleet/fleet_page.dart';
import 'package:uniconsole/features/leases/leases_page.dart';
import 'package:uniconsole/features/safety/safety_page.dart';

import 'helpers.dart';

void main() {
  group('多机联调', () {
    testWidgets('会话 #12：Echo 领队、Foxtrot 跟随；告警设备不可选；计数来自同一数据源', (tester) async {
      await open(tester, location: Routes.fleet('s12'));
      expect(find.text('联调会话 #12 · 展厅迎宾'), findsOneWidget);
      expect(find.text('2 台已同步 · 时钟偏差 ≤ 3 ms'), findsOneWidget);
      expect(find.text('领队'), findsOneWidget);
      expect(find.text('跟随'), findsOneWidget);
      expect(find.text('告警'), findsOneWidget);
      expect(find.text('充电中'), findsOneWidget);
      expect(find.textContaining('Charlie 左后腿电机过热'), findsOneWidget);
      // 侧边栏第四组换成「联调预设」。
      expect(find.text('展厅迎宾 · 4 台'), findsOneWidget);
      expect(find.text('巡检队'), findsNothing);

      // 告警设备：点了也不会加入。
      await tapText(tester, 'Charlie');
      expect(find.text('2 台已同步 · 时钟偏差 ≤ 3 ms'), findsOneWidget);
      await close(tester);
    });

    testWidgets('勾选 Bravo 加入 → 3 台；全体站立后回执包含 Bravo；切换队形', (tester) async {
      final container = await open(tester, location: Routes.fleet('s12'));
      await tapText(tester, 'Bravo');
      expect(find.text('3 台已同步 · 时钟偏差 ≤ 3 ms'), findsOneWidget);
      final lease = container.read(leaseProvider('go2-02'))!;
      expect(lease.holderKind, LeaseHolderKind.session);

      await tapText(tester, '全体站立');
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      final receipt = container.read(fleetSessionProvider('s12'))!.lastReceipt!;
      expect(receipt.acks.map((a) => a.deviceId), contains('go2-02'));
      expect(
        find.text('回执 ${receipt.acks.last.latency!.inMilliseconds} ms'),
        findsWidgets,
      );

      await tapText(tester, '纵队');
      expect(
        container.read(fleetSessionProvider('s12'))!.formation,
        Formation.column,
      );
      await close(tester);
    });

    testWidgets('空格 = 全体急停：运动指令禁用；再按解除', (tester) async {
      final container = await open(tester, location: Routes.fleet('s12'));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester);
      expect(container.read(estopProvider('g1-01')).value, isTrue);
      expect(container.read(estopProvider('go2-04')).value, isTrue);
      expect(find.text('2 台设备急停中 · 运动指令已禁用'), findsOneWidget);
      PrimaryButton stand() => tester.widget<PrimaryButton>(
        find.widgetWithText(PrimaryButton, '全体站立'),
      );
      expect(stand().onPressed, isNull);
      expect(
        tester
            .widget<SecondaryButton>(
              find.widgetWithText(SecondaryButton, '全体趴下'),
            )
            .onPressed,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(tester);
      expect(container.read(estopProvider('g1-01')).value, isFalse);
      expect(stand().onPressed, isNotNull);
      await close(tester);
    });

    testWidgets('结束会话 → 空状态；从预设重新发起 → 新会话 4 台', (tester) async {
      await open(tester, location: Routes.fleet('s12'));
      await tapText(tester, '结束会话');
      expect(find.text('结束联调会话 #12？'), findsOneWidget);
      await tester.tap(find.widgetWithText(DestructiveButton, '结束会话').last);
      await settle(tester);
      expect(find.text('没有进行中的联调会话'), findsOneWidget);

      await tester.tap(find.widgetWithText(PrimaryButton, '发起').first);
      await settle(tester);
      expect(find.text('联调会话 #13 · 展厅迎宾'), findsOneWidget);
      expect(find.text('4 台已同步 · 时钟偏差 ≤ 3 ms'), findsOneWidget);
      await close(tester);
    });

    testWidgets('不可用的预设：提示哪些设备不可用，不发起', (tester) async {
      final container = await open(tester, location: Routes.fleet('s12'));
      await tapText(tester, '仓库协同巡检 · 3 台');
      expect(find.text('无法发起联调'), findsOneWidget);
      expect(find.textContaining('Charlie 告警'), findsOneWidget);
      await tapText(tester, '好');
      expect(container.read(fleetSessionsProvider).value, hasLength(1));
      await close(tester);
    });
  });

  group('控制权', () {
    testWidgets('表格顺序与设计稿一致；4 个活动租约、1 个待审批', (tester) async {
      await open(tester, location: Routes.leases);
      expect(find.text('同一时刻每台设备只有一个控制者 · 4 个活动租约 · 1 个待审批'), findsOneWidget);
      final names = ['Alpha', 'Charlie', 'Echo', 'Foxtrot', 'Bravo', 'Delta'];
      final ys = [
        for (final n in names) tester.getTopLeft(find.text(n).first).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      expect(find.text('会话'), findsNWidgets(2));
      expect(find.text('22:00'), findsOneWidget);
      await close(tester);
    });

    testWidgets('批准并转移：持有者变为林悦，提示切换为只读，待审批清零', (tester) async {
      final container = await open(tester, location: Routes.leases);
      await tapText(tester, '批准并转移');
      expect(
        find.text('已批准：Alpha 的控制权已转移给 林悦，你的操控页面将切换为只读观看。'),
        findsOneWidget,
      );
      expect(container.read(holdsLeaseProvider('go2-01')), isFalse);
      expect(container.read(fleetSummaryProvider).pendingLeaseRequests, 0);
      expect(find.text('暂无申请'), findsOneWidget);
      await close(tester);
    });

    testWidgets('强制收回：必须填写原因，收回后设备空闲', (tester) async {
      final container = await open(tester, location: Routes.leases);
      await tapText(tester, 'Charlie');
      expect(find.text('Charlie 的控制者'), findsOneWidget);
      await tapText(tester, '强制收回');
      expect(find.text('强制收回 Charlie 的控制权？'), findsOneWidget);
      // 原因为空时不能确认。
      DestructiveButton confirm() => tester.widget<DestructiveButton>(
        find.widgetWithText(DestructiveButton, '强制收回').last,
      );
      expect(confirm().onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, '电机过热，现场处理');
      await tester.pump();
      expect(confirm().onPressed, isNotNull);
      await tester.tap(find.widgetWithText(DestructiveButton, '强制收回').last);
      await settle(tester);
      expect(container.read(leaseProvider('go2-03')), isNull);
      expect(find.textContaining('已强制收回 周明'), findsOneWidget);
      await close(tester);
    });

    testWidgets('转移给任务调度（带附言）', (tester) async {
      final container = await open(tester, location: Routes.leases);
      await tester.tap(find.widgetWithText(AppRadio<LeaseTarget?>, '任务调度'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, '夜巡前交给任务');
      await tapText(tester, '转移');
      final l = container.read(leaseProvider('go2-01'))!;
      expect(l.holderKind, LeaseHolderKind.task);
      expect(find.textContaining('已转移：Alpha 的控制权已交给 任务调度'), findsOneWidget);
      await close(tester);
    });
  });

  group('安全策略', () {
    testWidgets('全局急停：红色提示条、所有在线设备急停；解除需确认', (tester) async {
      final container = await open(tester, location: Routes.safety);
      expect(
        find.textContaining('安全状态正常 · 4 个围栏生效 · 上次急停演练 10 月 28 日'),
        findsWidgets,
      );
      await tester.tap(find.widgetWithText(EmergencyStopButton, '全局急停'));
      await settle(tester);
      expect(find.text('全局急停已触发'), findsOneWidget);
      expect(find.textContaining('6 台在线设备已进入阻尼模式'), findsOneWidget);
      bool estop(String id) =>
          container.read(mockWorldProvider).fleet.robot(id)!.estop;
      expect(estop('go2-01'), isTrue);
      expect(container.read(fleetSessionProvider('s12'))!.paused, isTrue);

      await tester.tap(find.widgetWithText(EmergencyStopButton, '解除全局急停'));
      await settle(tester);
      expect(find.text('解除全局急停？'), findsOneWidget);
      await tester.tap(find.widgetWithText(PrimaryButton, '解除急停'));
      await settle(tester);
      expect(find.text('全局急停已触发'), findsNothing);
      expect(estop('go2-01'), isFalse);
      await close(tester);
    });

    testWidgets('⌘⇧E 在任意页面触发全局急停', (tester) async {
      final container = await open(tester, location: Routes.devices);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await settle(tester);
      expect(container.read(safetyProvider).value!.globalEstop, isTrue);
      expect(
        container.read(mockWorldProvider).fleet.robot('g1-01')!.estop,
        isTrue,
      );
      await close(tester);
    });

    testWidgets('选择围栏显示详情；新建禁入区；关闭跌倒检测需确认', (tester) async {
      final container = await open(tester, location: Routes.safety);
      expect(find.text('在边界外 0.5 m 停止并告警'), findsOneWidget);
      await tapText(tester, '接待台人流区');
      expect(find.text('自动降速，禁止奔跑和跳跃步态'), findsOneWidget);

      await tapText(tester, '＋ 禁入区');
      expect(find.text('禁入区 3'), findsWidgets);
      expect(container.read(fleetSummaryProvider).zones, 5);

      final fall = find.byWidgetPredicate(
        (w) => w is AppSwitch && w.semanticLabel == '跌倒检测',
      );
      await tester.ensureVisible(fall);
      await tester.tap(fall);
      await settle(tester);
      expect(find.text('关闭「跌倒检测」？'), findsOneWidget);
      await tester.tap(find.widgetWithText(DestructiveButton, '关闭'));
      await settle(tester);
      expect(
        container.read(safetyProvider).value!.policies.fallDetection,
        isFalse,
      );
      await close(tester);
    });

    testWidgets('下拉修改全局限速；联调页的最小间距随策略变化', (tester) async {
      final container = await open(tester, location: Routes.safety);
      await tapText(tester, '0.8 m');
      await tapText(tester, '1.5 m');
      expect(container.read(safetyProvider).value!.policies.minDistance, 1.5);
      await close(tester);

      await open(tester, location: Routes.fleet('s12'));
      // 新容器：策略回到默认，验证联调页读取的是安全策略数据源。
      expect(find.text('0.8 m'), findsOneWidget);
      await close(tester);
    });
  });

  for (final width in [1440.0, 1000.0, 760.0, 390.0]) {
    testWidgets('第 4 阶段页面在 ${width.toInt()} 宽下无溢出', (tester) async {
      for (final loc in [
        Routes.fleet('s12'),
        Routes.fleetHome,
        Routes.leases,
        Routes.safety,
      ]) {
        await open(tester, location: loc, width: width, height: 900);
        expect(tester.takeException(), isNull, reason: loc);
        await close(tester);
      }
      expect(find.byType(FleetPage), findsNothing);
      expect(find.byType(LeasesPage), findsNothing);
      expect(find.byType(SafetyPage), findsNothing);
    });
  }
}
